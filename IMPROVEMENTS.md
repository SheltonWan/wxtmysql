# 连接池改进清单

## ✅ 已完成的改进

### 1. 自动连接管理
- ✅ 添加 `ManagedConnection` 类实现自动归还
- ✅ 添加 `query()` 方法自动管理连接
- ✅ 添加 `transaction()` 方法自动管理事务
- ✅ 添加 `getManagedConnection()` 方法

### 2. 连接泄漏检测
- ✅ 添加 `detectLeaks()` 方法检测长时间未归还的连接
- ✅ 在维护周期自动检测泄漏
- ✅ 详细的泄漏警告日志

### 3. 健康检查
- ✅ 添加 `healthCheck()` 方法全面诊断连接池状态
- ✅ 计算连接使用率、平均连接年龄
- ✅ 检测潜在问题并提供建议

### 4. 增强的错误处理
- ✅ 改进归还连接逻辑，防止重复归还
- ✅ 添加连接状态检查
- ✅ 查询失败时自动归还连接

### 5. 便利方法
- ✅ 添加 `queryPrepared()` 参数化查询
- ✅ 添加 `queryMulti()` 批量查询
- ✅ 添加 `isReturned` 状态检查

## 🔄 建议的进一步改进

### 1. 连接池动态调整
```dart
/// 根据负载动态调整连接池大小
class AdaptivePoolConfig extends ConnectionPoolConfig {
  final bool enableAutoScaling;
  final int scaleUpThreshold; // 使用率超过此值时扩展
  final int scaleDownThreshold; // 使用率低于此值时收缩

  const AdaptivePoolConfig({
    this.enableAutoScaling = false,
    this.scaleUpThreshold = 80, // 80%
    this.scaleDownThreshold = 20, // 20%
    super.minConnections,
    super.maxConnections,
  });
}
```

### 2. 连接重试机制
```dart
/// 连接失败时的重试策略
class ConnectionRetryPolicy {
  final int maxRetries;
  final Duration initialDelay;
  final Duration maxDelay;
  final double backoffMultiplier;

  const ConnectionRetryPolicy({
    this.maxRetries = 3,
    this.initialDelay = Duration(milliseconds: 100),
    this.maxDelay = Duration(seconds: 5),
    this.backoffMultiplier = 2.0,
  });
}
```

### 3. 连接预热
```dart
/// 预先建立并验证最小连接数
Future<void> warmup() async {
  await initialize();

  // 预先验证所有连接
  for (final conn in _connections) {
    await _validateConnection(conn);
  }

  _logger.info('Connection pool warmed up with ${_connections.length} connections');
}
```

### 4. 慢查询日志
```dart
/// 记录执行时间超过阈值的查询
Future<Results> query(String sql, [List<Object?>? values]) async {
  final startTime = DateTime.now();
  try {
    final results = await _executeQuery(sql, values);
    final duration = DateTime.now().difference(startTime);

    if (duration.inMilliseconds > _config.slowQueryThreshold) {
      _logger.warning('Slow query detected (${duration.inMilliseconds}ms): $sql');
    }

    return results;
  } catch (e) {
    rethrow;
  }
}
```

### 5. 连接池指标导出
```dart
/// 导出 Prometheus 指标
String exportMetrics() {
  final stats = getStats();
  return '''
# HELP mysql_pool_connections_total Total number of connections
# TYPE mysql_pool_connections_total gauge
mysql_pool_connections_total ${stats.totalConnections}

# HELP mysql_pool_connections_active Active connections
# TYPE mysql_pool_connections_active gauge
mysql_pool_connections_active ${stats.activeConnections}

# HELP mysql_pool_connections_idle Idle connections
# TYPE mysql_pool_connections_idle gauge
mysql_pool_connections_idle ${stats.idleConnections}

# HELP mysql_pool_waiting_requests Requests waiting for connection
# TYPE mysql_pool_waiting_requests gauge
mysql_pool_waiting_requests ${stats.waitingRequests}
''';
}
```

### 6. 连接池事件监听
```dart
/// 连接池事件
enum PoolEvent {
  connectionCreated,
  connectionClosed,
  connectionAcquired,
  connectionReleased,
  connectionLeaked,
  poolExhausted,
}

/// 事件监听器
typedef PoolEventListener = void Function(PoolEvent event, Map<String, dynamic> data);

/// 添加事件监听
void addEventListener(PoolEventListener listener) {
  _eventListeners.add(listener);
}

/// 触发事件
void _emitEvent(PoolEvent event, Map<String, dynamic> data) {
  for (final listener in _eventListeners) {
    try {
      listener(event, data);
    } catch (e) {
      _logger.warning('Error in event listener: $e');
    }
  }
}
```

### 7. 连接池快照
```dart
/// 生成连接池快照用于调试
Map<String, dynamic> snapshot() {
  return {
    'timestamp': DateTime.now().toIso8601String(),
    'stats': getStats().toMap(),
    'connections': _connections.map((c) => {
      'inUse': c.inUse,
      'inTransaction': c.inTransaction,
      'age': DateTime.now().difference(c.createdAt).inMinutes,
      'idleTime': DateTime.now().difference(c.lastUsedAt).inSeconds,
    }).toList(),
    'waitingQueue': _waitingQueue.length,
  };
}
```

### 8. 连接优先级
```dart
/// 支持高优先级请求快速获取连接
Future<PooledConnection> getConnection({Priority priority = Priority.normal}) async {
  // 高优先级请求插入队列前面
  if (priority == Priority.high && _waitingQueue.isNotEmpty) {
    // 实现优先级逻辑
  }
  // ...
}
```

### 9. 连接标签
```dart
/// 为连接添加标签，便于追踪和调试
class TaggedConnection extends ManagedConnection {
  final String tag;
  final Map<String, dynamic> metadata;

  TaggedConnection(super.pooledConnection, super.pool, this.tag, [this.metadata = const {}]);
}

Future<TaggedConnection> getConnectionWithTag(String tag, [Map<String, dynamic>? metadata]) async {
  final conn = await getConnection();
  return TaggedConnection(conn, this, tag, metadata ?? {});
}
```

### 10. 批量操作优化
```dart
/// 批量插入优化
Future<int> batchInsert(String table, List<Map<String, dynamic>> rows) async {
  if (rows.isEmpty) return 0;

  final conn = await getManagedConnection();
  try {
    return await conn.transaction((ctx) async {
      int inserted = 0;
      for (final row in rows) {
        final columns = row.keys.join(', ');
        final placeholders = List.filled(row.length, '?').join(', ');
        final sql = 'INSERT INTO $table ($columns) VALUES ($placeholders)';
        await ctx.query(sql, row.values.toList());
        inserted++;
      }
      return inserted;
    });
  } finally {
    await conn.release();
  }
}
```

## 📊 性能优化建议

### 1. 连接预分配
- 在高峰时段前预先创建连接
- 避免突发请求导致的延迟

### 2. 连接复用策略
- 优先复用最近使用的连接（热连接）
- 减少连接验证开销

### 3. 查询缓存
- 对于频繁执行的相同查询，缓存结果
- 减少数据库负载

### 4. 连接池分片
- 为不同类型的查询创建独立的连接池
- 读写分离，查询和事务分离

## 🔒 安全性改进

### 1. 连接加密
- 强制使用 SSL/TLS 连接
- 证书验证

### 2. 凭证轮换
- 支持动态更新数据库凭证
- 不需要重启服务

### 3. 审计日志
- 记录所有连接获取和释放操作
- 便于安全审计

## 📝 使用建议总结

1. **开发环境**
   - 使用小连接池（2-5个连接）
   - 启用详细日志
   - 启用连接泄漏检测（短超时）

2. **生产环境**
   - 根据负载调整连接池大小
   - 启用健康检查端点
   - 监控连接池指标
   - 定期导出健康报告

3. **高并发场景**
   - 增加最大连接数
   - 减少连接验证频率
   - 使用连接池分片
   - 考虑读写分离

4. **低延迟要求**
   - 预先创建连接（warmup）
   - 减少连接超时时间
   - 使用连接保活
   - 避免连接验证开销
