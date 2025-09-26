import 'dart:io';

import 'package:dotenv/dotenv.dart' as dotenv;
import 'package:logging/logging.dart';
import 'package:mysql1/mysql1.dart';
import 'package:synchronized/synchronized.dart';
import 'connection_pool.dart';
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
  Future<void> initialize() async {
    if (_connectionPool != null) {
      _logger.info('Connection pool already initialized');
      return;
    }

    final settings = ConnectionSettings(
      host: _host,
      port: _port,
      user: _username,
      password: _password,
      db: _database,
    );

    final config = _poolConfig ?? const ConnectionPoolConfig();
    _connectionPool = ConnectionPool(settings, config);
    
    await _connectionPool!.initialize();
    _logger.info('DatabaseService initialized with connection pool');
  }

  /// 确保连接池已初始化
  Future<ConnectionPool> _ensureInitialized() async {
    if (_connectionPool == null) {
      await initialize();
    }
    return _connectionPool!;
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
}
