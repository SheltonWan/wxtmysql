import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';
import 'package:mysql1/mysql1.dart';
import 'package:synchronized/synchronized.dart';
import 'package:wxtmysql/pooled_connection.dart';

import 'connection_pool_config.dart';
import 'connection_pool_stats.dart';

/// 高性能连接池实现
class ConnectionPool {
  final ConnectionSettings _settings;
  final ConnectionPoolConfig _config;
  final Logger _logger = Logger('ConnectionPool');

  final List<PooledConnection> _connections = [];
  final Queue<Completer<PooledConnection>> _waitingQueue = Queue();
  final Lock _poolLock = Lock();

  Timer? _maintenanceTimer;
  bool _isClosing = false;
  bool _initialized = false;

  // 添加统计计数器
  int _totalTimeouts = 0;
  int _totalRequests = 0;
  DateTime? _lastTimeoutAt;

  ConnectionPool(this._settings, [ConnectionPoolConfig? config]) : _config = config ?? const ConnectionPoolConfig() {
    _config.validate();
  }

  /// 初始化连接池
  Future<void> initialize() async {
    if (_initialized) return;

    await _poolLock.synchronized(() async {
      if (_initialized) return;

      _logger.info('Initializing connection pool with config: '
          'min=${_config.minConnections}, max=${_config.maxConnections}');

      // 创建最小连接数
      for (int i = 0; i < _config.minConnections; i++) {
        try {
          final pooledConn = await _createConnection();
          _connections.add(pooledConn);
          _logger.fine('Created initial connection ${i + 1}/${_config.minConnections}');
        } catch (e) {
          _logger.severe('❌ Failed to create initial connection ${i + 1}: $e');
          // 如果无法创建最小连接数，抛出异常
          if (i == 0) rethrow;
        }
      }

      // 启动维护定时器
      _startMaintenanceTimer();
      _initialized = true;
      _logger.info('Connection pool initialized with ${_connections.length} connections');
    });
  }

  /// 获取连接
  Future<PooledConnection> getConnection() async {
    _totalRequests++; // 统计总请求数

    if (_isClosing) {
      throw StateError('Connection pool is closing');
    }

    // 在锁外检查初始化状态，避免嵌套锁定
    if (!_initialized) {
      await initialize();
    }

    // 尝试快速获取空闲连接或创建新连接（使用短锁）
    PooledConnection? connection = await _poolLock.synchronized(() async {
      // 双重检查，确保在获取锁后仍然已初始化
      if (!_initialized) {
        throw StateError('Connection pool not initialized');
      }

      // 尝试获取空闲连接
      final idleConnection = _findIdleConnection();
      if (idleConnection != null) {
        idleConnection.markInUse();
        _logger.fine('✅ Reusing idle connection');
        return idleConnection;
      }

      return null; // 需要创建新连接或等待
    });

    if (connection != null) {
      return connection;
    }

    // 尝试创建新连接（在锁外进行网络操作）
    if (_connections.length < _config.maxConnections) {
      try {
        final newConnection = await _createConnection();

        // 在锁内添加到池中
        final added = await _poolLock.synchronized(() async {
          // 双重检查，防止并发创建过多连接
          if (_connections.length < _config.maxConnections) {
            _connections.add(newConnection);
            newConnection.markInUse();
            _logger.info('✅ Created new connection (${_connections.length}/${_config.maxConnections})');
            return true;
          }
          return false;
        });

        if (added) {
          return newConnection;
        } else {
          // 超出限制，关闭新创建的连接
          await newConnection.connection.close();
          _logger.warning('⚠️ Connection limit reached, closing excess connection');
        }
      } catch (e) {
        _logger.severe('❌ Failed to create new connection: $e');
      }
    }

    // 检查快速失败模式
    if (_config.enableFastFail) {
      throw StateError('All connections in use, fast-fail enabled. Pool stats: ${getStats()}');
    }

    // 检查等待队列是否已满（在锁外检查）
    final currentQueueLength = _waitingQueue.length;
    if (currentQueueLength >= _config.maxWaitingRequests) {
      throw StateError('Too many waiting requests ($currentQueueLength/${_config.maxWaitingRequests}). '
          'Pool stats: ${getStats()}');
    }

    // 所有连接都在使用中，需要等待
    _logger.warning(
        '⚠️ All connections in use, adding to wait queue (${currentQueueLength + 1}/${_config.maxWaitingRequests})');
    return _waitForConnectionOptimized();
  }

  /// 归还连接
  Future<void> returnConnection(PooledConnection pooledConnection) async {
    Completer<PooledConnection>? waiter;

    await _poolLock.synchronized(() async {
      if (_connections.contains(pooledConnection)) {
        pooledConnection.markIdle();
        _logger.fine('✅ Connection returned to pool');

        // 处理等待队列
        if (_waitingQueue.isNotEmpty) {
          waiter = _waitingQueue.removeFirst();
          pooledConnection.markInUse();
          _logger.info('✅ Connection assigned to waiting request (queue: ${_waitingQueue.length})');
        }
      }
    });

    // 在锁外完成等待者，避免潜在的死锁
    if (waiter != null && !waiter!.isCompleted) {
      waiter!.complete(pooledConnection);
    }
  }

  /// 获取连接池统计信息（线程安全版本）
  ConnectionPoolStats getStats() {
    // 为了避免在锁内调用时的潜在问题，这里创建快照
    final connectionsCopy = List<PooledConnection>.from(_connections);
    final waitingQueueLength = _waitingQueue.length;

    return ConnectionPoolStats(
      totalConnections: connectionsCopy.length,
      activeConnections: connectionsCopy.where((c) => c.inUse).length,
      idleConnections: connectionsCopy.where((c) => !c.inUse && !c.isInvalid).length,
      waitingRequests: waitingQueueLength,
      invalidConnections: connectionsCopy.where((c) => c.isInvalid).length,
    );
  }

  /// 健康检查 - 检查连接池是否健康
  Future<Map<String, dynamic>> healthCheck() async {
    final stats = getStats();
    final healthInfo = <String, dynamic>{
      'pool_status': _isClosing ? 'closing' : (_initialized ? 'healthy' : 'not_initialized'),
      'stats': stats.toMap(),
      'invalid_connections': _connections.where((c) => c.isInvalid).length,
      'expired_connections': _connections.where((c) => !c.inUse && c.isExpired(_config.maxIdleTime)).length,
      'timeout_statistics': {
        'total_timeouts': _totalTimeouts,
        'total_requests': _totalRequests,
        'timeout_rate_percent':
            _totalRequests > 0 ? (_totalTimeouts / _totalRequests * 100).toStringAsFixed(2) : '0.00',
        'last_timeout_at': _lastTimeoutAt?.toIso8601String(),
      },
      'config': {
        'min_connections': _config.minConnections,
        'max_connections': _config.maxConnections,
        'max_wait_time': _config.maxWaitTime,
        'max_waiting_requests': _config.maxWaitingRequests,
        'fast_fail_enabled': _config.enableFastFail,
      },
    };

    // 检查潜在问题
    final issues = <String>[];
    if (stats.waitingRequests > 0) {
      issues.add('有 ${stats.waitingRequests} 个请求在等待连接');
      if (stats.waitingRequests > _config.maxWaitingRequests * 0.8) {
        issues.add('等待队列接近饱和 (${stats.waitingRequests}/${_config.maxWaitingRequests})');
      }
    }
    if (stats.activeConnections == _config.maxConnections) {
      issues.add('连接池已达到最大连接数 ${_config.maxConnections}');
    }
    if (_connections.where((c) => c.isInvalid).length > 0) {
      issues.add('发现 ${_connections.where((c) => c.isInvalid).length} 个无效连接');
    }
    if (_config.enableFastFail) {
      issues.add('快速失败模式已启用');
    }

    healthInfo['issues'] = issues;
    healthInfo['health_score'] = _calculateHealthScore(stats, issues.length);

    return healthInfo;
  }

  /// 计算健康评分 (0-100)
  int _calculateHealthScore(ConnectionPoolStats stats, int issueCount) {
    int score = 100;

    // 等待请求扣分 - 根据等待队列饱和度
    if (stats.waitingRequests > 0) {
      final queueUtilization = stats.waitingRequests / _config.maxWaitingRequests;
      score -= (queueUtilization * 40).round(); // 队列满时扣40分
    }

    // 连接池使用率扣分
    final connectionUtilization = stats.totalConnections / _config.maxConnections;
    if (connectionUtilization >= 0.9) {
      score -= 20; // 使用率超过90%扣20分
    } else if (connectionUtilization >= 0.8) {
      score -= 10; // 使用率超过80%扣10分
    }

    // 每个问题扣分
    score -= issueCount * 10;

    // 如果启用快速失败且连接池满，额外扣分
    if (_config.enableFastFail && connectionUtilization >= 1.0) {
      score -= 30;
    }

    return score.clamp(0, 100);
  }

  /// 关闭连接池
  Future<void> close() async {
    _isClosing = true;
    _maintenanceTimer?.cancel();

    await _poolLock.synchronized(() async {
      _logger.info('Closing connection pool...');

      // 拒绝所有等待的请求
      while (_waitingQueue.isNotEmpty) {
        final waiter = _waitingQueue.removeFirst();
        waiter.completeError(StateError('Connection pool is closing'));
      }

      // 关闭所有连接
      for (final pooledConn in _connections) {
        try {
          await pooledConn.connection.close();
        } catch (e) {
          _logger.warning('Error closing connection: $e');
        }
      }
      _connections.clear();

      _logger.info('Connection pool closed');
    });
  }

  /// 创建新连接
  Future<PooledConnection> _createConnection() async {
    final connection =
        await MySqlConnection.connect(_settings).timeout(Duration(milliseconds: _config.connectionTimeout));
    return PooledConnection(connection);
  }

  /// 查找空闲连接
  PooledConnection? _findIdleConnection() {
    for (final pooledConn in _connections) {
      if (!pooledConn.inUse && !pooledConn.isInvalid && !pooledConn.isExpired(_config.maxIdleTime)) {
        return pooledConn;
      }
    }
    return null;
  }

  /// 等待连接可用（优化版本）
  Future<PooledConnection> _waitForConnectionOptimized() async {
    final completer = Completer<PooledConnection>();

    // 在锁内添加到等待队列
    await _poolLock.synchronized(() async {
      if (_waitingQueue.length >= _config.maxWaitingRequests) {
        throw StateError('Wait queue is full');
      }
      _waitingQueue.add(completer);
    });

    // 在锁外设置超时，避免锁冲突
    late Timer timeoutTimer;
    timeoutTimer = Timer(Duration(milliseconds: _config.maxWaitTime), () {
      if (!completer.isCompleted) {
        _totalTimeouts++;
        _lastTimeoutAt = DateTime.now();

        // 异步移除，避免在超时回调中持有锁
        _removeFromWaitQueueAsync(completer).then((_) {
          final timeoutRate = _totalRequests > 0 ? (_totalTimeouts / _totalRequests * 100).toStringAsFixed(2) : '0.00';

          _logger.warning('⚠️ Connection request timed out after ${_config.maxWaitTime}ms');
          _logger.warning(
              '⚠️ Timeout statistics: $_totalTimeouts timeouts out of $_totalRequests total requests ($timeoutRate% timeout rate)');

          if (!completer.isCompleted) {
            completer.completeError(TimeoutException(
              'Timeout waiting for connection after ${_config.maxWaitTime}ms. Timeout rate: $timeoutRate%',
              Duration(milliseconds: _config.maxWaitTime),
            ));
          }
        });
      }
    });

    try {
      final connection = await completer.future;
      timeoutTimer.cancel();
      return connection;
    } catch (e) {
      timeoutTimer.cancel();
      await _removeFromWaitQueueAsync(completer);
      _logger.severe('❌ Connection request failed: $e');
      rethrow;
    }
  }

  /// 异步移除等待队列中的请求
  Future<void> _removeFromWaitQueueAsync(Completer<PooledConnection> completer) async {
    try {
      await _poolLock.synchronized(() async {
        _waitingQueue.remove(completer);
      });
    } catch (e) {
      _logger.warning('Error removing from wait queue: $e');
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

      final toRemove = <PooledConnection>[];

      // 检查过期和无效连接
      for (final pooledConn in _connections) {
        if (pooledConn.inUse) continue;

        // 移除无效连接
        if (pooledConn.isInvalid) {
          toRemove.add(pooledConn);
          _logger.fine('Removing invalid connection');
          continue;
        }

        // 移除过期连接
        if (pooledConn.isExpired(_config.maxIdleTime)) {
          toRemove.add(pooledConn);
          _logger.fine('Removing expired connection');
          continue;
        }

        // 验证连接
        if (pooledConn.needsValidation(_config.validationInterval)) {
          if (await _validateConnection(pooledConn)) {
            pooledConn.markValidated();
          } else {
            pooledConn.isInvalid = true;
            toRemove.add(pooledConn);
            _logger.fine('Removing failed validation connection');
          }
        }
      }

      // 移除无效连接
      for (final pooledConn in toRemove) {
        _connections.remove(pooledConn);
        try {
          await pooledConn.connection.close();
        } catch (e) {
          _logger.warning('Error closing invalid connection: $e');
        }
      }

      // 确保最小连接数
      while (_connections.length < _config.minConnections && !_isClosing) {
        try {
          final newConnection = await _createConnection();
          _connections.add(newConnection);
          _logger.fine('Added connection to maintain minimum pool size');
        } catch (e) {
          _logger.severe('Failed to maintain minimum connections: $e');
          break;
        }
      }

      _logger.info('Maintenance completed: ${getStats()}');
    });
  }

  /// 标记连接为无效
  Future<void> markConnectionInvalid(PooledConnection pooledConnection) async {
    await _poolLock.synchronized(() async {
      if (_connections.contains(pooledConnection)) {
        pooledConnection.isInvalid = true;
        _logger.warning('⚠️ Connection marked as invalid');
      }
    });
  }

  /// 验证连接
  Future<bool> _validateConnection(PooledConnection pooledConn) async {
    try {
      await pooledConn.connection.query(_config.validationQuery).timeout(Duration(milliseconds: 5000));
      return true;
    } catch (e) {
      _logger.fine('Connection validation failed: $e');
      return false;
    }
  }
}
