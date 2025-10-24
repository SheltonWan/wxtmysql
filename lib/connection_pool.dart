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
    this.maxConnections = 10,
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

  PooledConnection(this.connection)
      : createdAt = DateTime.now(),
        lastUsedAt = DateTime.now(),
        inUse = false,
        inTransaction = false;

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

/// 连接资源包装器 - 自动管理连接生命周期
class ManagedConnection {
  final PooledConnection _pooledConnection;
  final ConnectionPool _pool;
  bool _returned = false;

  ManagedConnection(this._pooledConnection, this._pool);

  /// 获取原始MySQL连接（仅在必要时使用）
  MySqlConnection get connection => _pooledConnection.connection;

  /// 检查连接是否已归还
  bool get isReturned => _returned;

  /// 执行查询（自动归还连接）
  Future<Results> query(String sql, [List<Object?>? values]) async {
    _checkNotReturned();
    try {
      return await _pooledConnection.connection.query(sql, values);
    } catch (e) {
      // 查询失败也要归还连接
      await _ensureReturned();
      rethrow;
    }
  }

  /// 执行准备语句查询（mysql1包中prepare方法的包装）
  Future<Results> queryPrepared(String sql, List<Object?> values) async {
    _checkNotReturned();
    try {
      // mysql1 的 query 方法已经支持参数化查询，这里直接使用
      return await _pooledConnection.connection.query(sql, values);
    } catch (e) {
      await _ensureReturned();
      rethrow;
    }
  }

  /// 执行多个查询（批量操作）
  Future<List<Results>> queryMulti(List<String> sqls, [List<List<Object?>?>? valuesList]) async {
    _checkNotReturned();
    try {
      final results = <Results>[];
      for (var i = 0; i < sqls.length; i++) {
        final values = valuesList != null && i < valuesList.length ? valuesList[i] : null;
        results.add(await _pooledConnection.connection.query(sqls[i], values));
      }
      return results;
    } catch (e) {
      await _ensureReturned();
      rethrow;
    }
  }

  /// 执行事务（自动归还连接）
  Future<T> transaction<T>(Future<T> Function(TransactionContext) fn) async {
    _checkNotReturned();
    _pooledConnection.inTransaction = true;
    try {
      final result = await _pooledConnection.connection.transaction(fn);
      await _ensureReturned();
      return result as T;
    } catch (e) {
      await _ensureReturned();
      rethrow;
    }
  }

  /// 手动归还连接
  Future<void> release() async {
    await _ensureReturned();
  }

  /// 检查连接是否已归还
  void _checkNotReturned() {
    if (_returned) {
      throw StateError('Connection has already been returned to pool');
    }
  }

  /// 确保连接被归还（幂等）
  Future<void> _ensureReturned() async {
    if (!_returned) {
      _returned = true;
      await _pool.returnConnection(_pooledConnection);
    }
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
          _logger.fine('Created new connection (${_connections.length}/${_config.maxConnections})');
          return newConnection;
        } catch (e) {
          _logger.severe('Failed to create new connection: $e');
          // 创建连接失败，继续等待现有连接
        }
      }

      // 所有连接都在使用中，需要等待
      _logger.fine('All connections in use, waiting...');
      return _waitForConnection();
    });
  }

  /// 获取托管连接（推荐使用，自动归还）
  Future<ManagedConnection> getManagedConnection() async {
    final pooledConn = await getConnection();
    return ManagedConnection(pooledConn, this);
  }

  /// 执行查询（自动管理连接）
  Future<Results> query(String sql, [List<Object?>? values]) async {
    final managedConn = await getManagedConnection();
    try {
      return await managedConn.query(sql, values);
    } finally {
      await managedConn.release();
    }
  }

  /// 执行事务（自动管理连接）
  Future<T> transaction<T>(Future<T> Function(TransactionContext) fn) async {
    final managedConn = await getManagedConnection();
    try {
      return await managedConn.transaction(fn);
    } finally {
      await managedConn.release();
    }
  }

  /// 归还连接
  Future<void> returnConnection(PooledConnection pooledConnection) async {
    await _poolLock.synchronized(() async {
      if (!_connections.contains(pooledConnection)) {
        _logger.warning('Attempted to return unknown connection');
        return;
      }

      if (!pooledConnection.inUse) {
        _logger.warning('Attempted to return connection that is not in use');
        return;
      }

      pooledConnection.markIdle();
      _logger.fine('Connection returned to pool (${getStats()})');

      // 处理等待队列
      if (_waitingQueue.isNotEmpty) {
        final waiter = _waitingQueue.removeFirst();
        if (!waiter.isCompleted) {
          pooledConnection.markInUse();
          waiter.complete(pooledConnection);
          _logger.fine('Connection assigned to waiting request');
        }
      }
    });
  }

  /// 获取连接池统计信息
  ConnectionPoolStats getStats() {
    return ConnectionPoolStats(
      totalConnections: _connections.length,
      activeConnections: _connections.where((c) => c.inUse).length,
      idleConnections: _connections.where((c) => !c.inUse).length,
      waitingRequests: _waitingQueue.length,
    );
  }

  /// 检测连接泄漏
  void detectLeaks() {
    final now = DateTime.now();
    final leakedConnections = _connections.where((c) {
      return c.inUse && now.difference(c.lastUsedAt).inMinutes > 5; // 超过5分钟未归还
    }).toList();

    if (leakedConnections.isNotEmpty) {
      _logger.warning('Detected ${leakedConnections.length} potentially leaked connections:');
      for (final conn in leakedConnections) {
        _logger.warning('  - In use for ${now.difference(conn.lastUsedAt).inMinutes} minutes, '
            'transaction: ${conn.inTransaction}');
      }
    }
  }

  /// 健康检查
  Future<Map<String, dynamic>> healthCheck() async {
    final stats = getStats();
    final now = DateTime.now();

    // 计算连接使用率
    final utilizationRate = stats.totalConnections > 0
        ? (stats.activeConnections / stats.totalConnections * 100).toStringAsFixed(1)
        : '0.0';

    // 检查是否有等待的请求
    final hasBacklog = stats.waitingRequests > 0;

    // 检查是否接近最大连接数
    final nearMaxCapacity = stats.totalConnections >= (_config.maxConnections * 0.8);

    // 计算连接年龄
    final connectionAges = _connections.map((c) => now.difference(c.createdAt).inMinutes).toList();

    final avgAge = connectionAges.isNotEmpty
        ? (connectionAges.reduce((a, b) => a + b) / connectionAges.length).toStringAsFixed(1)
        : '0.0';

    // 检测泄漏
    final leakedCount = _connections.where((c) {
      return c.inUse && now.difference(c.lastUsedAt).inMinutes > 5;
    }).length;

    final isHealthy =
        !hasBacklog && !nearMaxCapacity && leakedCount == 0 && stats.totalConnections >= _config.minConnections;

    return {
      'healthy': isHealthy,
      'timestamp': now.toIso8601String(),
      'stats': stats.toMap(),
      'metrics': {
        'utilizationRate': '$utilizationRate%',
        'averageConnectionAge': '$avgAge minutes',
        'leakedConnections': leakedCount,
        'nearMaxCapacity': nearMaxCapacity,
        'hasBacklog': hasBacklog,
      },
      'config': {
        'minConnections': _config.minConnections,
        'maxConnections': _config.maxConnections,
        'maxWaitTime': _config.maxWaitTime,
      },
      'issues': _getHealthIssues(stats, leakedCount, hasBacklog, nearMaxCapacity),
    };
  }

  /// 获取健康问题列表
  List<String> _getHealthIssues(ConnectionPoolStats stats, int leakedCount, bool hasBacklog, bool nearMaxCapacity) {
    final issues = <String>[];

    if (leakedCount > 0) {
      issues.add('$leakedCount connections may be leaked (in use > 5 minutes)');
    }

    if (hasBacklog) {
      issues.add('${stats.waitingRequests} requests waiting for connection');
    }

    if (nearMaxCapacity) {
      issues.add('Pool near max capacity (${stats.totalConnections}/${_config.maxConnections})');
    }

    if (stats.totalConnections < _config.minConnections) {
      issues.add('Pool below minimum connections (${stats.totalConnections}/${_config.minConnections})');
    }

    if (stats.idleConnections == 0 && stats.totalConnections < _config.maxConnections) {
      issues.add('No idle connections available, consider increasing pool size');
    }

    return issues;
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
      if (!pooledConn.inUse && !pooledConn.isExpired(_config.maxIdleTime)) {
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
        completer.completeError(TimeoutException(
          'Timeout waiting for connection',
          Duration(milliseconds: _config.maxWaitTime),
        ));
      }
    });

    return completer.future;
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

      // 检测连接泄漏
      detectLeaks();

      final toRemove = <PooledConnection>[];

      // 检查过期和无效连接
      for (final pooledConn in _connections) {
        if (pooledConn.inUse) continue;

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
            toRemove.add(pooledConn);
            _logger.fine('Removing invalid connection');
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

      final stats = getStats();
      _logger.fine('Maintenance completed: $stats');

      // 如果有等待的请求但没有空闲连接，记录警告
      if (stats.waitingRequests > 0 && stats.idleConnections == 0) {
        _logger.warning('Pool exhausted: ${stats.waitingRequests} requests waiting, '
            '${stats.activeConnections}/${stats.totalConnections} connections in use');
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
