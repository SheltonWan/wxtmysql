import 'dart:async';
import 'dart:collection';
import 'package:logging/logging.dart';
import 'package:mysql1/mysql1.dart';
import 'package:synchronized/synchronized.dart';

/// 连接池配置
class ConnectionPoolConfig {
  /// 最小连接数
  final int minConnections;

  /// 最大连接数
  final int maxConnections;

  /// 连接超时时间（毫秒）
  final int connectionTimeout;

  /// 连接最大空闲时间（毫秒）
  final int maxIdleTime;

  /// 连接验证查询
  final String validationQuery;

  /// 连接验证间隔（毫秒）
  final int validationInterval;

  /// 获取连接最大等待时间（毫秒）
  final int maxWaitTime;

  const ConnectionPoolConfig({
    this.minConnections = 2,
    this.maxConnections = 20,
    this.connectionTimeout = 30000, // 30秒
    this.maxIdleTime = 300000, // 5分钟
    this.validationQuery = 'SELECT 1',
    this.validationInterval = 60000, // 1分钟
    this.maxWaitTime = 10000, // 10秒
  });

  /// 验证配置参数
  void validate() {
    if (minConnections < 0) {
      throw ArgumentError('minConnections must be >= 0');
    }
    if (maxConnections <= 0) {
      throw ArgumentError('maxConnections must be > 0');
    }
    if (minConnections > maxConnections) {
      throw ArgumentError('minConnections must be <= maxConnections');
    }
    if (connectionTimeout <= 0) {
      throw ArgumentError('connectionTimeout must be > 0');
    }
    if (maxIdleTime <= 0) {
      throw ArgumentError('maxIdleTime must be > 0');
    }
    if (validationInterval <= 0) {
      throw ArgumentError('validationInterval must be > 0');
    }
    if (maxWaitTime <= 0) {
      throw ArgumentError('maxWaitTime must be > 0');
    }
  }
}

/// 池化连接包装类
class PooledConnection {
  final MySqlConnection connection;
  final DateTime createdAt;
  DateTime lastUsedAt;
  DateTime? lastValidatedAt;
  bool inUse;
  bool inTransaction;
  bool isInvalid; // 新增：标记连接是否无效

  PooledConnection(this.connection)
      : createdAt = DateTime.now(),
        lastUsedAt = DateTime.now(),
        inUse = false,
        inTransaction = false,
        isInvalid = false; // 初始化为有效连接

  /// 检查连接是否过期
  bool isExpired(int maxIdleTime) {
    return DateTime.now().difference(lastUsedAt).inMilliseconds > maxIdleTime;
  }

  /// 检查是否需要验证
  bool needsValidation(int validationInterval) {
    if (lastValidatedAt == null) return true;
    return DateTime.now().difference(lastValidatedAt!).inMilliseconds > validationInterval;
  }

  /// 标记为使用中
  void markInUse() {
    inUse = true;
    lastUsedAt = DateTime.now();
  }

  /// 标记为空闲
  void markIdle() {
    inUse = false;
    inTransaction = false;
    lastUsedAt = DateTime.now();
  }

  /// 标记验证时间
  void markValidated() {
    lastValidatedAt = DateTime.now();
  }
}

/// 连接池统计信息
class ConnectionPoolStats {
  final int totalConnections;
  final int activeConnections;
  final int idleConnections;
  final int waitingRequests;
  final DateTime timestamp;

  ConnectionPoolStats({
    required this.totalConnections,
    required this.activeConnections,
    required this.idleConnections,
    required this.waitingRequests,
  }) : timestamp = DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'totalConnections': totalConnections,
      'activeConnections': activeConnections,
      'idleConnections': idleConnections,
      'waitingRequests': waitingRequests,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  @override
  String toString() {
    return 'ConnectionPool(total: $totalConnections, active: $activeConnections, '
           'idle: $idleConnections, waiting: $waitingRequests)';
  }
}

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

  ConnectionPool(this._settings, [ConnectionPoolConfig? config])
      : _config = config ?? const ConnectionPoolConfig() {
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
          _logger.severe('Failed to create initial connection ${i + 1}: $e');
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
    if (_isClosing) {
      throw StateError('Connection pool is closing');
    }

    if (!_initialized) {
      await initialize();
    }

    return await _poolLock.synchronized(() async {
      // 尝试获取空闲连接
      final idleConnection = _findIdleConnection();
      if (idleConnection != null) {
        idleConnection.markInUse();
        _logger.fine('Reusing idle connection');
        return idleConnection;
      }

      // 如果没有空闲连接且未达到最大连接数，创建新连接
      if (_connections.length < _config.maxConnections) {
        try {
          final newConnection = await _createConnection();
          _connections.add(newConnection);
          newConnection.markInUse();
          _logger.info('Created new connection (${_connections.length}/${_config.maxConnections})');
          return newConnection;
        } catch (e) {
          _logger.severe('Failed to create new connection: $e');
          // 创建连接失败，继续等待现有连接
        }
      }

      // 所有连接都在使用中，需要等待
      _logger.severe('All connections in use, waiting...');
      return _waitForConnection();
    });
  }

  /// 归还连接
  Future<void> returnConnection(PooledConnection pooledConnection) async {
    await _poolLock.synchronized(() async {
      if (_connections.contains(pooledConnection)) {
        pooledConnection.markIdle();
        _logger.fine('Connection returned to pool');

        // 处理等待队列
        if (_waitingQueue.isNotEmpty) {
          final waiter = _waitingQueue.removeFirst();
          pooledConnection.markInUse();
          waiter.complete(pooledConnection);
          _logger.info('Connection assigned to waiting request');
        }
      }
    });
  }

  /// 获取连接池统计信息
  ConnectionPoolStats getStats() {
    return ConnectionPoolStats(
      totalConnections: _connections.length,
      activeConnections: _connections.where((c) => c.inUse).length,
      idleConnections: _connections.where((c) => !c.inUse && !c.isInvalid).length,
      waitingRequests: _waitingQueue.length,
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
      'config': {
        'min_connections': _config.minConnections,
        'max_connections': _config.maxConnections,
        'max_wait_time': _config.maxWaitTime,
      },
    };

    // 检查潜在问题
    final issues = <String>[];
    if (stats.waitingRequests > 0) {
      issues.add('有 ${stats.waitingRequests} 个请求在等待连接');
    }
    if (stats.activeConnections == _config.maxConnections) {
      issues.add('连接池已达到最大连接数 ${_config.maxConnections}');
    }
    if (_connections.where((c) => c.isInvalid).length > 0) {
      issues.add('发现 ${_connections.where((c) => c.isInvalid).length} 个无效连接');
    }

    healthInfo['issues'] = issues;
    healthInfo['health_score'] = _calculateHealthScore(stats, issues.length);

    return healthInfo;
  }

  /// 计算健康评分 (0-100)
  int _calculateHealthScore(ConnectionPoolStats stats, int issueCount) {
    int score = 100;
    
    // 等待请求扣分
    if (stats.waitingRequests > 0) {
      score -= (stats.waitingRequests * 10).clamp(0, 30);
    }
    
    // 连接池满扣分
    if (stats.totalConnections >= _config.maxConnections) {
      score -= 20;
    }
    
    // 每个问题扣分
    score -= issueCount * 15;
    
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
    final connection = await MySqlConnection.connect(_settings)
        .timeout(Duration(milliseconds: _config.connectionTimeout));
    return PooledConnection(connection);
  }

  /// 查找空闲连接
  PooledConnection? _findIdleConnection() {
    for (final pooledConn in _connections) {
      if (!pooledConn.inUse && 
          !pooledConn.isInvalid && 
          !pooledConn.isExpired(_config.maxIdleTime)) {
        return pooledConn;
      }
    }
    return null;
  }

  /// 等待连接可用
  Future<PooledConnection> _waitForConnection() async {
    final completer = Completer<PooledConnection>();
    _waitingQueue.add(completer);

    // 设置超时
    Timer(Duration(milliseconds: _config.maxWaitTime), () {
      if (!completer.isCompleted) {
        _waitingQueue.remove(completer);
        _logger.warning('Connection request timed out after ${_config.maxWaitTime}ms, '
                       'pool stats: ${getStats()}');
        completer.completeError(TimeoutException(
          'Timeout waiting for connection after ${_config.maxWaitTime}ms. '
          'Pool stats: ${getStats()}',
          Duration(milliseconds: _config.maxWaitTime),
        ));
      }
    });

    try {
      return await completer.future;
    } catch (e) {
      // 确保从等待队列中移除（防止重复移除）
      _waitingQueue.remove(completer);
      rethrow;
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
        _logger.warning('Connection marked as invalid');
      }
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
