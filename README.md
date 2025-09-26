# WxtMySQL# WXT MySQL - 线程安全的 MySQL 数据库服务



一个高性能的 MySQL 数据库连接池库，专为 Flutter/Dart 应用设计。支持连接池管理、事务处理、并发安全和数据库自动创建。一个功能完整、线程安全的 Dart MySQL 数据库连接服务包。



## 主要特性



- 🚀 **高性能连接池**: 支持 2-10 个并发连接的智能管理## 🔥 主要职责

- 🔒 **并发安全**: 线程安全的数据库操作- **数据库连接管理**：提供 MySQL 数据库的连接建立、维护和关闭

- 🔄 **事务支持**: 完整的 ACID 事务处理- **配置管理**：从环境变量和 .env 文件加载数据库配置

- 🛠 **自动初始化**: 数据库存在检查和自动创建- **SQL 操作封装**：封装常见的 CRUD 操作（查询、插入、更新、删除）

- 📊 **健康监控**: 连接池状态监控和自动维护- **事务管理**：提供线程安全的事务开始、提交、回滚功能

- ⚙️ **灵活配置**: 多种预设配置和自定义选项- **连接池管理**：维护单一连接实例，避免重复连接

- 🌏 **中文优化**: 支持中文字符集和排序规则- **错误处理和日志记录**：统一的异常处理和操作日志



## 快速开始## � 核心功能

- **单例模式**：确保全局只有一个数据库服务实例

### 1. 添加依赖- **线程安全**：使用 Lock 机制保护所有并发操作

- **连接复用**：智能检测现有连接状态，避免不必要的重连

```yaml- **配置灵活性**：支持多种配置来源（.env 文件、系统环境变量、默认值）

dependencies:- **事务支持**：提供手动和自动事务管理，防止嵌套事务

  wxtmysql: ^1.0.0- **状态监控**：实时连接状态和事务状态检查

```- **维护功能**：包含连接测试、版本查询、过期会话清理等工具方法



### 2. 环境配置## ⭐ 优点分析



在项目根目录创建 `.env` 文件：### 1. 并发安全设计

- 使用 `synchronized` 包提供的 Lock 机制

```env- 连接操作完全线程安全

DB_HOST=localhost- 事务串行化执行，避免数据竞争

DB_PORT=3306

DB_USER=your_username### 2. 设计模式运用得当

DB_PASSWORD=your_password- 采用单例模式，避免多个实例造成资源浪费

DB_NAME=your_database- 连接复用机制，提高性能

```

### 3. 配置管理灵活

### 3. 基本使用- 支持多级配置：.env 文件 → 系统环境变量 → 默认值

- 使用 `EnvKeys` 类集中管理配置键名，避免硬编码

```dart

import 'package:wxtmysql/wxtmysql.dart';### 4. 完整的数据库操作封装

- 提供了 CRUD 的完整实现

void main() async {- 事务支持完整（手动控制 + 自动回滚）

  final dbService = DatabaseService.instance;- 返回值有意义（插入返回ID，更新/删除返回影响行数）

  

  // 初始化连接池（自动检查和创建数据库）### 5. 错误处理和日志记录

  await dbService.initialize(- 完善的异常捕获和重新抛出

    ensureDatabase: true,  // 确保数据库存在- 详细的日志记录，便于调试和监控

    charset: 'utf8mb4',- 不同级别的日志（info、warning、severe、fine）

    collate: 'utf8mb4_unicode_ci',

  );### 6. 连接健康检查

  - 连接前检测现有连接是否可用

  // 执行查询- 提供 `testConnection()` 方法主动检测

  final results = await dbService.query(- 连接失败时自动重连机制
    'SELECT * FROM users WHERE age > ?',
    [18]
  );
  
  print(results);
  
  // 关闭连接池
  await dbService.close();
}
```

## 核心功能

### 连接池管理

连接池自动管理 2-10 个数据库连接，根据负载动态调整：

```dart
final dbService = DatabaseService.instance;

// 初始化连接池
await dbService.initialize();

// 获取连接池状态
final stats = dbService.getDetailedStats();
print('活跃连接数: ${stats['activeConnections']}');
print('空闲连接数: ${stats['idleConnections']}');
```

### 数据库自动创建

支持在初始化时自动检查和创建数据库：

```dart
// 方式 1: 基本初始化
await dbService.initialize(
  ensureDatabase: true,  // 自动创建数据库
  charset: 'utf8mb4',
  collate: 'utf8mb4_unicode_ci',
);

// 方式 2: 使用预设配置
await dbService.initializeWithConfig(DatabaseInitConfig.chineseOptimized);

// 手动检查数据库是否存在
final exists = await dbService.databaseExists();
if (!exists) {
  await dbService.createDatabase();
}
```

### 预设配置

提供多种预设配置方便使用：

```dart
// 开发环境配置
await dbService.initializeWithConfig(DatabaseInitConfig.development);

// 生产环境配置  
await dbService.initializeWithConfig(DatabaseInitConfig.production);

// 中文优化配置
await dbService.initializeWithConfig(DatabaseInitConfig.chineseOptimized);

// 高性能配置
await dbService.initializeWithConfig(DatabaseInitConfig.highPerformance);
```

### CRUD 操作

```dart
// 查询
final users = await dbService.query(
  'SELECT * FROM users WHERE status = ?',
  ['active']
);

// 插入
final userId = await dbService.insert(
  'INSERT INTO users (name, email) VALUES (?, ?)',
  ['张三', 'zhang@example.com']
);

// 更新
final affectedRows = await dbService.update(
  'UPDATE users SET last_login = NOW() WHERE id = ?',
  [userId]
);

// 删除
await dbService.delete(
  'DELETE FROM users WHERE id = ?',
  [userId]
);
```

### 事务处理

支持完整的事务操作，确保数据一致性：

```dart
await dbService.transaction((tx) async {
  // 扣减余额
  await tx.update(
    'UPDATE accounts SET balance = balance - ? WHERE id = ?',
    [amount, fromAccountId]
  );
  
  // 增加余额
  await tx.update(
    'UPDATE accounts SET balance = balance + ? WHERE id = ?',
    [amount, toAccountId]
  );
  
  // 记录转账日志
  await tx.insert(
    'INSERT INTO transfer_logs (from_id, to_id, amount, created_at) VALUES (?, ?, ?, NOW())',
    [fromAccountId, toAccountId, amount]
  );
});
```

### 数据库架构管理

内置常用的架构管理工具：

```dart
// 检查表是否存在
final tableExists = await dbService.query(
  DatabaseSchemaManager.checkTableExists('users'),
  ['users']
);

// 创建用户表
if ((tableExists.first['count'] as int) == 0) {
  await dbService.query(DatabaseSchemaManager.createUsersTable);
}

// 创建会话表
await dbService.query(DatabaseSchemaManager.createSessionsTable);
```

## 高级特性

### 自定义配置

```dart
final customConfig = DatabaseInitConfig(
  ensureDatabase: true,
  charset: 'utf8mb4',
  collate: 'utf8mb4_general_ci',
  connectionTimeout: 30,
  autoCreate: true,
  verboseLogging: false,
);

await dbService.initializeWithConfig(customConfig);
```

### 监控和统计

```dart
// 获取详细统计信息
final stats = dbService.getDetailedStats();
print('总连接数: ${stats['totalConnections']}');
print('活跃连接数: ${stats['activeConnections']}');
print('空闲连接数: ${stats['idleConnections']}');
print('总查询数: ${stats['totalQueries']}');

// 获取数据库信息
final dbInfo = await dbService.getDatabaseInfo();
print('数据库版本: ${dbInfo['version']}');
print('字符集: ${dbInfo['charset']}');
```

### 错误处理

```dart
try {
  await dbService.query('SELECT * FROM users');
} on DatabaseException catch (e) {
  print('数据库错误: ${e.message}');
  print('错误代码: ${e.code}');
} catch (e) {
  print('其他错误: $e');
}
```

## 最佳实践

### 1. 连接池配置

- 开发环境：使用较少连接数（2-5个）
- 生产环境：根据并发量配置连接数（5-10个）
- 定期监控连接池状态

### 2. 事务使用

- 只在需要数据一致性时使用事务
- 保持事务尽可能短小
- 避免在事务中执行耗时操作

### 3. 错误处理

- 始终使用 try-catch 处理数据库操作
- 区分不同类型的数据库错误
- 实现适当的重试机制

### 4. 字符集配置

- 中文应用推荐使用 `utf8mb4`
- 排序规则推荐 `utf8mb4_unicode_ci`
- 表情符号支持需要 `utf8mb4`

## 示例项目

查看 `example/` 目录下的完整示例：

- `database_auto_init_demo.dart` - 数据库自动初始化演示
- `connection_pool_demo.dart` - 连接池使用演示
- `transaction_demo.dart` - 事务处理演示

## API 文档

### DatabaseService

| 方法 | 描述 |
|------|------|
| `initialize()` | 初始化连接池 |
| `initializeWithConfig()` | 使用配置初始化 |
| `query()` | 执行查询 |
| `insert()` | 插入数据 |
| `update()` | 更新数据 |
| `delete()` | 删除数据 |
| `transaction()` | 执行事务 |
| `databaseExists()` | 检查数据库是否存在 |
| `createDatabase()` | 创建数据库 |
| `close()` | 关闭连接池 |

### DatabaseInitConfig

预设配置：

- `DatabaseInitConfig.development` - 开发环境
- `DatabaseInitConfig.production` - 生产环境  
- `DatabaseInitConfig.chineseOptimized` - 中文优化
- `DatabaseInitConfig.highPerformance` - 高性能

## 版本历史

- **v1.0.0** - 初始版本，连接池和基本功能
- **v1.1.0** - 添加事务支持和错误处理
- **v1.2.0** - 新增数据库自动创建功能

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request！