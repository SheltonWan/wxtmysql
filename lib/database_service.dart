import 'dart:io';

import 'package:dotenv/dotenv.dart' as dotenv;
import 'package:logging/logging.dart';
import 'package:mysql1/mysql1.dart';
import 'package:synchronized/synchronized.dart';
import 'connection_pool.dart';
import 'database_init_config.dart';
import 'env_keys.dart';

/// 数据库事务处理类
class DatabaseTransaction {
  final PooledConnection _pooledConnection;
  final Logger _logger = Logger('DatabaseTransaction');

  DatabaseTransaction._(this._pooledConnection);

  /// 执行查询
  Future<Results> query(String sql, [List<Object?>? values]) async {
    try {
      _logger.fine('Executing transaction query: $sql');
      return await _pooledConnection.connection.query(sql, values);
    } catch (e) {
      _logger.severe('Transaction query failed: $sql, Error: $e');
      rethrow;
    }
  }

  /// 执行插入并返回插入的ID
  Future<int> insert(String sql, [List<Object?>? values]) async {
    final result = await query(sql, values);
    return result.insertId ?? 0;
  }

  /// 执行更新
  Future<int> update(String sql, [List<Object?>? values]) async {
    final result = await query(sql, values);
    return result.affectedRows ?? 0;
  }

  /// 执行删除
  Future<int> delete(String sql, [List<Object?>? values]) async {
    final result = await query(sql, values);
    return result.affectedRows ?? 0;
  }

  /// 手动提交事务（通常不需要，事务会自动提交）
  Future<void> commit() async {
    await _pooledConnection.connection.query('COMMIT');
    _logger.fine('Transaction manually committed');
  }

  /// 手动回滚事务
  Future<void> rollback() async {
    await _pooledConnection.connection.query('ROLLBACK');
    _logger.fine('Transaction manually rolled back');
  }
}


/// MySQL数据库连接服务 - 支持高并发连接池
class DatabaseService {

  /// 私有构造函数
  DatabaseService._() {
    _initializeConfig();
  }
  
  /// 工厂构造函数，支持自定义连接池配置
  /// 注意：只能在首次创建实例时使用，如果已有实例则会抛出异常
  factory DatabaseService.withConfig(ConnectionPoolConfig config) {
    if (_instance != null) {
      throw StateError('DatabaseService instance already exists. Use DatabaseService.instance instead, or call DatabaseService.reset() first.');
    }
    final service = DatabaseService._();
    service._poolConfig = config;
    _instance = service; // 确保设置实例
    return service;
  }

  static DatabaseService? _instance;
  static DatabaseService get instance => _instance ??= DatabaseService._();

  /// 重置单例实例（主要用于测试或重新配置）
  /// 警告：这会关闭现有的连接池
  static Future<void> reset() async {
    if (_instance != null) {
      await _instance!.close();
      _instance = null;
    }
  }

  final Logger _logger = Logger('DatabaseService');
  
  // 连接池相关
  ConnectionPool? _connectionPool;
  ConnectionPoolConfig? _poolConfig;
  
  // 事务管理 - 现在使用连接级别的事务
  final Map<PooledConnection, bool> _connectionTransactions = {};
  final Lock _transactionMapLock = Lock();

  // 数据库配置
  late final String _host;
  late final int _port;
  late final String _database;
  late final String _username;
  late final String _password;

  /// 获取连接池实例（仅用于高级操作）
  ConnectionPool? get connectionPool => _connectionPool;

  String get databaseName => _database;
  
  /// 检查连接池是否已初始化
  bool get isInitialized => _connectionPool != null;
  
  /// 获取连接池统计信息
  ConnectionPoolStats? get poolStats => _connectionPool?.getStats();
  
  /// 检查是否有活跃连接
  bool get hasActiveConnections {
    final stats = poolStats;
    return stats != null && stats.totalConnections > 0;
  }

  /// 初始化数据库配置
  void _initializeConfig() {
    final env = dotenv.DotEnv(includePlatformEnvironment: true)..load(); // 加载.env文件

    _host = env[EnvKeys.dbHost] ?? Platform.environment[EnvKeys.dbHost] ?? 'localhost';
    _port = int.tryParse(env[EnvKeys.dbPort] ??
            Platform.environment[EnvKeys.dbPort] ??
            '3306') ??
        3306;
    _database = env[EnvKeys.dbName] ??
        Platform.environment[EnvKeys.dbName] ??
        'auth_db';
    _username = env[EnvKeys.dbUser] ??
        Platform.environment[EnvKeys.dbUser] ??
        'db_user';
    _password = env[EnvKeys.dbPassword] ??
        Platform.environment[EnvKeys.dbPassword] ??
        'db_password';

    _logger.info('Database config: $_host:$_port/$_database');
  }

  /// 初始化连接池
  /// [ensureDatabase] 是否确保数据库存在，如果不存在则创建
  /// [charset] 创建数据库时使用的字符集，默认 utf8mb4
  /// [collate] 创建数据库时使用的排序规则，默认 utf8mb4_unicode_ci
  Future<void> initialize({
    bool ensureDatabase = true,
    String charset = 'utf8mb4',
    String collate = 'utf8mb4_unicode_ci',
  }) async {
    return initializeWithConfig(DatabaseInitConfig(
      ensureDatabase: ensureDatabase,
      charset: charset,
      collate: collate,
    ));
  }

  /// 使用配置对象初始化连接池
  Future<void> initializeWithConfig(DatabaseInitConfig config) async {
    if (_connectionPool != null) {
      _logger.info('Connection pool already initialized');
      return;
    }

    if (config.verboseLogging) {
      _logger.info('Initializing DatabaseService with config: $config');
    }

    // 如果需要确保数据库存在，先检查和创建
    if (config.ensureDatabase) {
      await _ensureDatabaseExists(config.charset, config.collate);
    }

    final settings = ConnectionSettings(
      host: _host,
      port: _port,
      user: _username,
      password: _password,
      db: _database,
    );

    final poolConfig = _poolConfig ?? const ConnectionPoolConfig();
    _connectionPool = ConnectionPool(settings, poolConfig);
    
    await _connectionPool!.initialize();
    
    if (config.verboseLogging) {
      _logger.info('DatabaseService initialized successfully with connection pool');
      final dbInfo = await getDatabaseInfo();
      _logger.info('Database info: $dbInfo');
    } else {
      _logger.info('DatabaseService initialized with connection pool');
    }
  }

  /// 确保连接池已初始化
  Future<ConnectionPool> _ensureInitialized() async {
    if (_connectionPool == null) {
      await initialize();
    }
    return _connectionPool!;
  }

  /// 确保目标数据库存在，如果不存在则创建
  Future<void> _ensureDatabaseExists(String charset, String collate) async {
    MySqlConnection? adminConnection;
    
    try {
      _logger.info('Checking if database "$_database" exists...');
      
      // 创建不指定数据库的管理连接
      final adminSettings = ConnectionSettings(
        host: _host,
        port: _port,
        user: _username,
        password: _password,
        // 不指定 db，连接到 MySQL 服务器
      );

      adminConnection = await MySqlConnection.connect(adminSettings)
          .timeout(Duration(seconds: 30));

      // 检查数据库是否存在
      final result = await adminConnection.query(
        'SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = ?',
        [_database]
      );

      if (result.isEmpty) {
        _logger.info('Database "$_database" does not exist, creating...');
        
        // 创建数据库
        await adminConnection.query(
          'CREATE DATABASE `$_database` CHARACTER SET $charset COLLATE $collate'
        );
        
        _logger.info('Database "$_database" created successfully with charset: $charset, collate: $collate');
      } else {
        _logger.info('Database "$_database" already exists');
      }

    } catch (e) {
      _logger.severe('Failed to ensure database exists: $e');
      // 根据错误类型决定是否重新抛出异常
      if (e.toString().contains('Access denied') || 
          e.toString().contains('Unknown database')) {
        _logger.warning('Database creation failed, but will attempt to connect anyway: $e');
        // 不重新抛出，让后续的连接尝试处理
      } else {
        rethrow;
      }
    } finally {
      // 关闭管理连接
      try {
        await adminConnection?.close();
      } catch (e) {
        _logger.warning('Error closing admin connection: $e');
      }
    }
  }



  /// 执行数据库操作的通用方法
  Future<T> _executeWithConnection<T>(
    Future<T> Function(MySqlConnection) operation,
    [String? operationType]
  ) async {
    final pool = await _ensureInitialized();
    final pooledConnection = await pool.getConnection();
    
    try {
      _logger.fine('Executing ${operationType ?? 'operation'}');
      final result = await operation(pooledConnection.connection);
      return result;
    } catch (e) {
      _logger.severe('${operationType ?? 'Operation'} failed: $e');
      rethrow;
    } finally {
      await pool.returnConnection(pooledConnection);
    }
  }

  /// 执行查询
  Future<Results> query(String sql, [List<Object?>? values]) async {
    return await _executeWithConnection<Results>(
      (conn) => conn.query(sql, values),
      'Query: $sql'
    );
  }

  /// 执行插入并返回插入的ID
  Future<int> insert(String sql, [List<Object?>? values]) async {
    final result = await _executeWithConnection<Results>(
      (conn) => conn.query(sql, values),
      'Insert: $sql'
    );
    return result.insertId ?? 0;
  }

  /// 执行更新
  Future<int> update(String sql, [List<Object?>? values]) async {
    final result = await _executeWithConnection<Results>(
      (conn) => conn.query(sql, values),
      'Update: $sql'
    );
    return result.affectedRows ?? 0;
  }

  /// 执行删除
  Future<int> delete(String sql, [List<Object?>? values]) async {
    final result = await _executeWithConnection<Results>(
      (conn) => conn.query(sql, values),
      'Delete: $sql'
    );
    return result.affectedRows ?? 0;
  }

  /// 执行事务 - 新的连接级别事务支持
  Future<T> transaction<T>(Future<T> Function(DatabaseTransaction) operation) async {
    final pool = await _ensureInitialized();
    final pooledConnection = await pool.getConnection();
    
    // 标记连接为事务状态
    await _transactionMapLock.synchronized(() async {
      _connectionTransactions[pooledConnection] = true;
    });
    
    final transaction = DatabaseTransaction._(pooledConnection);
    
    try {
      await pooledConnection.connection.query('START TRANSACTION');
      _logger.fine('Transaction started on connection');
      
      final result = await operation(transaction);
      
      await pooledConnection.connection.query('COMMIT');
      _logger.fine('Transaction committed');
      
      return result;
    } catch (e) {
      _logger.warning('Transaction failed, rolling back: $e');
      try {
        await pooledConnection.connection.query('ROLLBACK');
        _logger.fine('Transaction rolled back');
      } catch (rollbackError) {
        _logger.severe('Failed to rollback transaction: $rollbackError');
      }
      rethrow;
    } finally {
      // 清除事务状态并归还连接
      await _transactionMapLock.synchronized(() async {
        _connectionTransactions.remove(pooledConnection);
      });
      pooledConnection.inTransaction = false;
      await pool.returnConnection(pooledConnection);
    }
  }
  


  /// 测试数据库连接池
  Future<bool> testConnection() async {
    try {
      await query('SELECT 1 as test');
      _logger.info('Database connection pool test successful');
      return true;
    } catch (e) {
      _logger.severe('Database connection pool test failed: $e');
      return false;
    }
  }

  /// 关闭连接池
  Future<void> close() async {
    if (_connectionPool != null) {
      _logger.info('Closing connection pool...');
      
      // 清除所有事务状态
      await _transactionMapLock.synchronized(() async {
        _connectionTransactions.clear();
      });
      
      await _connectionPool!.close();
      _connectionPool = null;
      _logger.info('Connection pool closed');
    }
  }

  /// 获取数据库版本信息
  Future<String> getVersion() async {
    try {
      final result = await query('SELECT VERSION() as version');
      return result.first['version'].toString();
    } catch (e) {
      _logger.warning('Failed to get database version: $e');
      return 'Unknown';
    }
  }

  /// 清理过期会话（手动调用）
  Future<int> cleanupExpiredSessions() async {
    try {
      final result = await delete('DELETE FROM sessions WHERE expires_at < NOW()');
      if (result > 0) {
        _logger.info('Cleaned up $result expired sessions');
      }
      return result;
    } catch (e) {
      _logger.severe('Failed to cleanup expired sessions: $e');
      return 0;
    }
  }
  
  /// 获取详细的性能统计信息
  Map<String, dynamic> getDetailedStats() {
    final stats = poolStats;
    if (stats == null) {
      return {'status': 'not_initialized'};
    }
    
    return {
      'pool_stats': stats.toMap(),
      'database': _database,
      'host': '$_host:$_port',
      'active_transactions': _connectionTransactions.length,
    };
  }

  /// 检查数据库是否存在
  Future<bool> databaseExists() async {
    try {
      // 尝试连接到目标数据库
      final testSettings = ConnectionSettings(
        host: _host,
        port: _port,
        user: _username,
        password: _password,
        db: _database,
      );

      final testConnection = await MySqlConnection.connect(testSettings)
          .timeout(Duration(seconds: 10));
      
      await testConnection.close();
      return true;
    } catch (e) {
      if (e.toString().contains('Unknown database')) {
        return false;
      }
      // 其他错误也认为数据库不存在或不可访问
      _logger.warning('Error checking database existence: $e');
      return false;
    }
  }

  /// 创建数据库（需要管理员权限）
  Future<void> createDatabase({
    String charset = 'utf8mb4',
    String collate = 'utf8mb4_unicode_ci',
    bool ifNotExists = true,
  }) async {
    MySqlConnection? adminConnection;
    
    try {
      _logger.info('Creating database "$_database"...');
      
      final adminSettings = ConnectionSettings(
        host: _host,
        port: _port,
        user: _username,
        password: _password,
      );

      adminConnection = await MySqlConnection.connect(adminSettings)
          .timeout(Duration(seconds: 30));

      final ifNotExistsClause = ifNotExists ? 'IF NOT EXISTS' : '';
      await adminConnection.query(
        'CREATE DATABASE $ifNotExistsClause `$_database` CHARACTER SET $charset COLLATE $collate'
      );
      
      _logger.info('Database "$_database" created successfully');
      
    } catch (e) {
      _logger.severe('Failed to create database: $e');
      rethrow;
    } finally {
      await adminConnection?.close();
    }
  }

  /// 删除数据库（危险操作，需要管理员权限）
  Future<void> dropDatabase({bool ifExists = true}) async {
    MySqlConnection? adminConnection;
    
    try {
      _logger.warning('Dropping database "$_database"...');
      
      final adminSettings = ConnectionSettings(
        host: _host,
        port: _port,
        user: _username,
        password: _password,
      );

      adminConnection = await MySqlConnection.connect(adminSettings)
          .timeout(Duration(seconds: 30));

      final ifExistsClause = ifExists ? 'IF EXISTS' : '';
      await adminConnection.query('DROP DATABASE $ifExistsClause `$_database`');
      
      _logger.warning('Database "$_database" dropped successfully');
      
      // 如果连接池已初始化，需要关闭它
      if (_connectionPool != null) {
        await close();
      }
      
    } catch (e) {
      _logger.severe('Failed to drop database: $e');
      rethrow;
    } finally {
      await adminConnection?.close();
    }
  }

  /// 获取数据库信息
  Future<Map<String, dynamic>> getDatabaseInfo() async {
    try {
      final charsetResult = await query(
        'SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME '
        'FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = ?',
        [_database]
      );

      final tablesResult = await query(
        'SELECT COUNT(*) as table_count FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ?',
        [_database]
      );

      final sizeResult = await query(
        'SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS size_mb '
        'FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ?',
        [_database]
      );

      return {
        'database_name': _database,
        'charset': charsetResult.isNotEmpty ? charsetResult.first['DEFAULT_CHARACTER_SET_NAME'] : 'unknown',
        'collation': charsetResult.isNotEmpty ? charsetResult.first['DEFAULT_COLLATION_NAME'] : 'unknown',
        'table_count': tablesResult.isNotEmpty ? tablesResult.first['table_count'] : 0,
        'size_mb': sizeResult.isNotEmpty ? (sizeResult.first['size_mb'] ?? 0) : 0,
        'host': '$_host:$_port',
      };
    } catch (e) {
      _logger.warning('Failed to get database info: $e');
      return {
        'database_name': _database,
        'error': e.toString(),
      };
    }
  }
}
