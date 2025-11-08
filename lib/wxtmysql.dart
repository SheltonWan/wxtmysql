library wxtmysql;

// 导出主要的数据库服务类
export 'database_service.dart' show DatabaseService, DatabaseTransaction;
export 'connection_pool.dart' show ConnectionPool;
export 'database_init_config.dart' show DatabaseInitConfig, DatabaseSchemaManager;
export 'connection_pool_config.dart' show ConnectionPoolConfig;
export 'semaphore_connection_pool.dart' show SemaphoreConnectionPool;
export 'pooled_connection.dart' show PooledConnection;
export 'connection_pool_stats.dart' show ConnectionPoolStats;
export 'abstract/i_connection_pool.dart' show IConnectionPool, ConnectionPoolType;
export 'env_keys.dart' show EnvKeys;

// 重新导出mysql1包的常用类型以便使用
export 'package:mysql1/mysql1.dart' show Results, Field, ConnectionSettings;
