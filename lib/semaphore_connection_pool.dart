import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';
import 'package:mysql1/mysql1.dart';
import 'package:synchronized/synchronized.dart';
import 'package:wxtmysql/pooled_connection.dart';

import 'abstract/i_connection_pool.dart';
import 'connection_pool_config.dart';
import 'connection_pool_stats.dart';

/// 使用信号量的连接池实现
class SemaphoreConnectionPool implements IConnectionPool {
  final ConnectionSettings _settings;
  final ConnectionPoolConfig _config;
  final Logger _logger = Logger('SemaphoreConnectionPool');

  /// 信号量控制最大连接数
  late final Semaphore _connectionSemaphore;

  /// 实际连接存储
  final Queue<PooledConnection> _availableConnections = Queue();
  final Set<PooledConnection> _allConnections = {};

  /// 保护连接池内部状态的锁（仅用于连接管理，不用于获取连接的等待）
  final Lock _poolLock = Lock();

  Timer? _maintenanceTimer;
  bool _isClosing = false;
  bool _initialized = false;

  // 统计信息
  int _totalRequests = 0;
  int _totalTimeouts = 0;
  DateTime? _lastTimeoutAt;

  @override
  ConnectionPoolType get type => ConnectionPoolType.semaphore;

  @override
  ConnectionPoolConfig get config => _config;

  @override
  ConnectionSettings get settings => _settings;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isClosing => _isClosing;

  @override
  String get typeName => type.toString().split('.').last;

  @override
  String get description => '信号量实现 - 高并发优化，适合高负载场景';

  SemaphoreConnectionPool(this._settings, [ConnectionPoolConfig? config])
      : _config = config ?? const ConnectionPoolConfig() {
    _config.validate();
    _connectionSemaphore = Semaphore(_config.maxConnections);
  }

  /// 初始化连接池
  @override
  Future<void> initialize() async {
    if (_initialized) return;

    await _poolLock.synchronized(() async {
      if (_initialized) return;

      _logger.info('Initializing semaphore-based connection pool with config: '
          'min=${_config.minConnections}, max=${_config.maxConnections}');

      // 创建最小连接数
      for (int i = 0; i < _config.minConnections; i++) {
        try {
          final pooledConn = await _createConnection();
          _availableConnections.add(pooledConn);
          _allConnections.add(pooledConn);
          _logger.fine('Created initial connection ${i + 1}/${_config.minConnections}');
        } catch (e) {
          _logger.severe('Failed to create initial connection ${i + 1}: $e');
          if (i == 0) rethrow;
        }
      }

      // 预获取信号量许可（对应已创建的连接）
      for (int i = 0; i < _availableConnections.length; i++) {
        await _connectionSemaphore.acquire();
      }

      _startMaintenanceTimer();
      _initialized = true;
      _logger.info('Connection pool initialized with ${_availableConnections.length} connections');
    });
  }

  /// 获取连接 - 使用信号量控制并发
  @override
  Future<PooledConnection> getConnection() async {
    _totalRequests++;

    if (_isClosing) {
      throw StateError('Connection pool is closing');
    }

    if (!_initialized) {
      await initialize();
    }

    _logger.fine('Requesting connection (attempt $_totalRequests)');

    // 第一步：获取信号量许可（控制最大连接数）
    final acquired = await _acquireWithTimeout();
    if (!acquired) {
      _totalTimeouts++;
      _lastTimeoutAt = DateTime.now();
      final timeoutRate = (_totalTimeouts / _totalRequests * 100).toStringAsFixed(2);
      _logger.warning('Connection request timed out. Timeout rate: $timeoutRate%');

      throw TimeoutException(
        'Timeout waiting for connection after ${_config.maxWaitTime}ms. '
        'Timeout rate: $timeoutRate%',
        Duration(milliseconds: _config.maxWaitTime),
      );
    }

    try {
      // 第二步：获取实际连接对象
      PooledConnection? connection = await _poolLock.synchronized(() async {
        // 尝试复用空闲连接
        while (_availableConnections.isNotEmpty) {
          final conn = _availableConnections.removeFirst();
          if (!conn.isInvalid && !conn.isExpired(_config.maxIdleTime)) {
            conn.markInUse();
            _logger.fine('Reusing idle connection');
            return conn;
          } else {
            // 移除无效连接
            _allConnections.remove(conn);
            _closeConnectionSafely(conn);
          }
        }
        return null;
      });

      // 如果没有可复用的连接，创建新连接
      if (connection == null) {
        final newConnection = await _createConnection();
        await _poolLock.synchronized(() async {
          _allConnections.add(newConnection);
          newConnection.markInUse();
        });
        connection = newConnection;
        _logger.info('Created new connection (${_allConnections.length}/${_config.maxConnections})');
      }

      return connection;
    } catch (e) {
      // 获取连接失败，释放信号量许可
      _connectionSemaphore.release();
      _logger.severe('Failed to get connection: $e');
      rethrow;
    }
  }

  /// 归还连接
  @override
  Future<void> returnConnection(PooledConnection pooledConnection) async {
    await _poolLock.synchronized(() async {
      if (_allConnections.contains(pooledConnection)) {
        pooledConnection.markIdle();

        if (!pooledConnection.isInvalid) {
          _availableConnections.add(pooledConnection);
          _logger.fine('Connection returned to pool');
        } else {
          _allConnections.remove(pooledConnection);
          _closeConnectionSafely(pooledConnection);
          _logger.warning('Invalid connection removed from pool');
        }
      }
    });

    // 释放信号量许可，允许其他请求获取连接
    _connectionSemaphore.release();
  }

  /// 带超时的信号量获取
  Future<bool> _acquireWithTimeout() async {
    if (_config.enableFastFail && _connectionSemaphore.isLocked) {
      return false;
    }

    try {
      await _connectionSemaphore.acquire()
          .timeout(Duration(milliseconds: _config.maxWaitTime));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// 标记连接为无效
  @override
  Future<void> markConnectionInvalid(PooledConnection pooledConnection) async {
    await _poolLock.synchronized(() async {
      if (_allConnections.contains(pooledConnection)) {
        pooledConnection.isInvalid = true;
        _logger.warning('Connection marked as invalid');
      }
    });
  }

  /// 获取连接池统计信息
  @override
  ConnectionPoolStats getStats() {
    final allConnectionsList = _allConnections.toList();
    return ConnectionPoolStats(
      totalConnections: allConnectionsList.length,
      activeConnections: allConnectionsList.where((c) => c.inUse).length,
      idleConnections: _availableConnections.length,
      waitingRequests: _connectionSemaphore.waitQueueLength,
      invalidConnections: allConnectionsList.where((c) => c.isInvalid).length,
    );
  }

  /// 健康检查
  @override
  Future<Map<String, dynamic>> healthCheck() async {
    final stats = getStats();
    return {
      'pool_status': _isClosing ? 'closing' : (_initialized ? 'healthy' : 'not_initialized'),
      'stats': stats.toMap(),
      'semaphore_permits_available': _connectionSemaphore.availablePermits,
      'semaphore_queue_length': _connectionSemaphore.waitQueueLength,
      'timeout_statistics': {
        'total_timeouts': _totalTimeouts,
        'total_requests': _totalRequests,
        'timeout_rate_percent':
            _totalRequests > 0 ? (_totalTimeouts / _totalRequests * 100).toStringAsFixed(2) : '0.00',
        'last_timeout_at': _lastTimeoutAt?.toIso8601String(),
      },
    };
  }

  /// 关闭连接池
  @override
  Future<void> close() async {
    _isClosing = true;
    _maintenanceTimer?.cancel();

    await _poolLock.synchronized(() async {
      _logger.info('Closing semaphore-based connection pool...');

      // 关闭所有连接
      for (final conn in _allConnections) {
        await _closeConnectionSafely(conn);
      }
      _allConnections.clear();
      _availableConnections.clear();

      _logger.info('Connection pool closed');
    });
  }

  /// 创建新连接
  Future<PooledConnection> _createConnection() async {
    final connection = await MySqlConnection.connect(_settings)
        .timeout(Duration(milliseconds: _config.connectionTimeout));
    return PooledConnection(connection);
  }

  /// 安全关闭连接
  Future<void> _closeConnectionSafely(PooledConnection conn) async {
    try {
      await conn.connection.close();
    } catch (e) {
      _logger.warning('Error closing connection: $e');
    }
  }

  /// 启动维护定时器
  void _startMaintenanceTimer() {
    _maintenanceTimer = Timer.periodic(
      Duration(milliseconds: _config.validationInterval),
      (_) => _performMaintenance(),
    );
  }

  /// 执行连接池维护
  Future<void> _performMaintenance() async {
    if (_isClosing) return;

    await _poolLock.synchronized(() async {
      _logger.fine('Performing connection pool maintenance');

      // 清理无效和过期的连接
      final toRemove = <PooledConnection>[];
      final availableList = _availableConnections.toList();

      for (final conn in availableList) {
        if (conn.isInvalid || conn.isExpired(_config.maxIdleTime)) {
          toRemove.add(conn);
        } else if (conn.needsValidation(_config.validationInterval)) {
          // 异步验证，避免阻塞维护任务
          _validateConnectionAsync(conn);
        }
      }

      // 移除无效连接
      for (final conn in toRemove) {
        _availableConnections.remove(conn);
        _allConnections.remove(conn);
        await _closeConnectionSafely(conn);
        // 释放对应的信号量许可
        _connectionSemaphore.release();
      }

      _logger.fine('Maintenance completed: ${getStats()}');
    });
  }

  /// 异步验证连接
  void _validateConnectionAsync(PooledConnection conn) {
    _validateConnection(conn).then((isValid) {
      if (!isValid) {
        conn.isInvalid = true;
      } else {
        conn.markValidated();
      }
    }).catchError((e) {
      _logger.warning('Connection validation error: $e');
      conn.isInvalid = true;
    });
  }

  /// 验证连接
  Future<bool> _validateConnection(PooledConnection pooledConn) async {
    try {
      await pooledConn.connection.query(_config.validationQuery)
          .timeout(Duration(milliseconds: 5000));
      return true;
    } catch (e) {
      _logger.fine('Connection validation failed: $e');
      return false;
    }
  }
}

/// 简单的信号量实现
class Semaphore {
  final int maxCount;
  int _currentCount;
  final Queue<Completer<void>> _waitQueue = Queue();

  Semaphore(this.maxCount) : _currentCount = maxCount;

  /// 可用许可数
  int get availablePermits => _currentCount;

  /// 等待队列长度
  int get waitQueueLength => _waitQueue.length;

  /// 是否已锁定（无可用许可）
  bool get isLocked => _currentCount <= 0;

  /// 获取许可
  Future<void> acquire() async {
    if (_currentCount > 0) {
      _currentCount--;
      return;
    }

    final completer = Completer<void>();
    _waitQueue.add(completer);
    return completer.future;
  }

  /// 释放许可
  void release() {
    if (_waitQueue.isNotEmpty) {
      final waiter = _waitQueue.removeFirst();
      waiter.complete();
    } else {
      _currentCount++;
      if (_currentCount > maxCount) {
        _currentCount = maxCount; // 防止过度释放
      }
    }
  }
}
