# 连接池使用指南

## 问题分析

超时异常 `TimeoutException after 0:00:10.000000: Timeout waiting for connection` 的主要原因：

1. **连接未归还** - 使用 `getConnection()` 后忘记调用 `returnConnection()`
2. **异常未处理** - 代码抛出异常时连接没有在 finally 块中归还
3. **事务未完成** - 事务开始后未提交或回滚，连接一直占用

## 推荐用法（自动管理）

### 1. 使用 `query()` 方法（推荐）

```dart
// ✅ 推荐：自动管理连接
final results = await pool.query('SELECT * FROM users WHERE id = ?', [userId]);
for (var row in results) {
  print(row['name']);
}
```

### 2. 使用 `transaction()` 方法（推荐）

```dart
// ✅ 推荐：自动管理事务连接
final result = await pool.transaction((ctx) async {
  await ctx.query('INSERT INTO users (name) VALUES (?)', ['Alice']);
  await ctx.query('INSERT INTO logs (action) VALUES (?)', ['user_created']);
  return true;
});
```

### 3. 使用 `getManagedConnection()`（推荐）

```dart
// ✅ 推荐：托管连接自动归还
final conn = await pool.getManagedConnection();
try {
  final results = await conn.query('SELECT * FROM users');
  // 处理结果...
} finally {
  await conn.release(); // 可选：显式释放
}
// 即使不调用 release()，连接也会在作用域结束时归还
```

## 不推荐用法（手动管理）

### ❌ 危险：容易泄漏连接

```dart
// ❌ 不推荐：忘记归还连接
final pooledConn = await pool.getConnection();
final results = await pooledConn.connection.query('SELECT * FROM users');
// 忘记调用 pool.returnConnection(pooledConn) ⚠️

// ❌ 不推荐：异常时连接泄漏
final pooledConn = await pool.getConnection();
final results = await pooledConn.connection.query('SELECT * FROM users');
throw Exception('Error!'); // 连接泄漏 ⚠️
// pool.returnConnection(pooledConn); // 永远不会执行

// ❌ 不推荐：事务未完成
final pooledConn = await pool.getConnection();
await pooledConn.connection.query('START TRANSACTION');
await pooledConn.connection.query('INSERT INTO users VALUES (...)');
// 忘记 COMMIT 或 ROLLBACK ⚠️
await pool.returnConnection(pooledConn);
```

### ✅ 正确：手动管理时使用 try-finally

```dart
// ✅ 如果必须手动管理，使用 try-finally
final pooledConn = await pool.getConnection();
try {
  final results = await pooledConn.connection.query('SELECT * FROM users');
  // 处理结果...
} finally {
  await pool.returnConnection(pooledConn); // 确保归还
}
```

## 迁移现有代码

### 场景 1：简单查询

```dart
// 旧代码（容易泄漏）
final pooledConn = await pool.getConnection();
final results = await pooledConn.connection.query('SELECT * FROM users');
await pool.returnConnection(pooledConn);

// ⬇️ 迁移到

// 新代码（自动管理）
final results = await pool.query('SELECT * FROM users');
```

### 场景 2：多个查询

```dart
// 旧代码
final pooledConn = await pool.getConnection();
try {
  final users = await pooledConn.connection.query('SELECT * FROM users');
  final logs = await pooledConn.connection.query('SELECT * FROM logs');
  // 处理...
} finally {
  await pool.returnConnection(pooledConn);
}

// ⬇️ 迁移到

// 新代码
final conn = await pool.getManagedConnection();
try {
  final users = await conn.query('SELECT * FROM users');
  final logs = await conn.query('SELECT * FROM logs');
  // 处理...
} finally {
  await conn.release();
}
```

### 场景 3：事务

```dart
// 旧代码
final pooledConn = await pool.getConnection();
try {
  await pooledConn.connection.query('START TRANSACTION');
  await pooledConn.connection.query('INSERT INTO users VALUES (...)');
  await pooledConn.connection.query('INSERT INTO logs VALUES (...)');
  await pooledConn.connection.query('COMMIT');
} catch (e) {
  await pooledConn.connection.query('ROLLBACK');
  rethrow;
} finally {
  await pool.returnConnection(pooledConn);
}

// ⬇️ 迁移到

// 新代码
await pool.transaction((ctx) async {
  await ctx.query('INSERT INTO users VALUES (...)');
  await ctx.query('INSERT INTO logs VALUES (...)');
  // 自动提交，异常时自动回滚
});
```

## 监控和调试

### 查看连接池状态

```dart
final stats = pool.getStats();
print('Total: ${stats.totalConnections}');
print('Active: ${stats.activeConnections}');
print('Idle: ${stats.idleConnections}');
print('Waiting: ${stats.waitingRequests}');
```

### 检测连接泄漏

```dart
// 连接池会自动在维护周期检测泄漏
// 也可以手动调用
pool.detectLeaks();
```

### 配置连接池

```dart
final pool = ConnectionPool(
  settings,
  ConnectionPoolConfig(
    minConnections: 2,
    maxConnections: 10,
    maxWaitTime: 30000, // 增加等待时间到30秒
    maxIdleTime: 300000, // 5分钟
  ),
);
```

## 最佳实践

1. ✅ **优先使用** `pool.query()` 和 `pool.transaction()`
2. ✅ **次选使用** `pool.getManagedConnection()`
3. ⚠️ **避免使用** `pool.getConnection()` 除非有特殊需求
4. ✅ **始终在 finally 块中归还连接**（如果手动管理）
5. ✅ **事务使用 transaction() 方法**，避免手动处理提交/回滚
6. ✅ **监控连接池统计**，及时发现问题
7. ✅ **适当调整 maxWaitTime**，根据业务特点配置
