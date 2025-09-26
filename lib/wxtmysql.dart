import 'dart:io';

import 'package:dotenv/dotenv.dart' as dotenv;
import 'package:logging/logging.dart';
import 'package:mysql1/mysql1.dart';
import 'package:synchronized/synchronized.dart';
import 'env_keys.dart';


/// MySQL数据库连接服务
class DatabaseService {

  /// 私有构造函数
  DatabaseService._() {
  _initializeConfig();
  }
  static DatabaseService? _instance;
  static DatabaseService get instance => _instance ??= DatabaseService._();

  final Logger _logger = Logger('DatabaseService');
  MySqlConnection? _connection;
  
  // 并发控制
  final Lock _connectionLock = Lock();
  final Lock _transactionLock = Lock();
  bool _isConnecting = false;
  bool _inTransaction = false;

  // 数据库配置
  late final String _host;
  late final int _port;
  late final String _database;
  late final String _username;
  late final String _password;

  MySqlConnection? get connection => _connection;

  String get databaseName => _database;
  
  /// 检查是否已连接
  bool get isConnected => _connection != null;
  
  /// 检查是否在事务中
  bool get inTransaction => _inTransaction;
  
  /// 检查是否正在连接
  bool get isConnecting => _isConnecting;

  /// 初始化数据库配置
  void _initializeConfig() {
  final env = dotenv.DotEnv(includePlatformEnvironment: true)..load(); // 加载.env文件

  _host =
    env[EnvKeys.dbHost] ?? Platform.environment[EnvKeys.dbHost] ?? 'localhost';
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



  /// 连接到数据库
  Future<MySqlConnection> connect() async {
    return await _connectionLock.synchronized(() async {
      // 如果正在连接中，等待连接完成
      if (_isConnecting) {
        while (_isConnecting) {
          await Future.delayed(Duration(milliseconds: 50));
        }
        if (_connection != null) return _connection!;
      }

      if (_connection != null) {
        try {
          // 测试现有连接
          await _connection!.query('SELECT 1');
          return _connection!;
        } catch (e) {
          _logger.warning('Existing connection failed, reconnecting: $e');
          await _closeConnection();
        }
      }

      _isConnecting = true;
      try {
        final settings = ConnectionSettings(
          host: _host,
          port: _port,
          user: _username,
          password: _password,
          db: _database,
        );

        _connection = await MySqlConnection.connect(settings);
        _logger.info('Successfully connected to MySQL database');
        return _connection!;
      } catch (e) {
        _logger.severe('Failed to connect to database: $e');
        rethrow;
      } finally {
        _isConnecting = false;
      }
    });
  }

  /// 安全关闭连接的私有方法
  Future<void> _closeConnection() async {
    if (_connection != null) {
      try {
        await _connection!.close();
      } catch (e) {
        _logger.warning('Error closing connection: $e');
      } finally {
        _connection = null;
        _inTransaction = false;
      }
    }
  }

  /// 执行查询
  Future<Results> query(String sql, [List<Object?>? values]) async {
  final conn = await connect();
  try {
    _logger.fine('Executing query: $sql');
    return await conn.query(sql, values);
  } catch (e) {
    _logger.severe('Query failed: $sql, Error: $e');
    rethrow;
  }
  }

  /// 执行插入并返回插入的ID
  Future<int> insert(String sql, [List<Object?>? values]) async {
  final conn = await connect();
  try {
    _logger.fine('Executing insert: $sql');
    final result = await conn.query(sql, values);
    return result.insertId ?? 0;
  } catch (e) {
    _logger.severe('Insert failed: $sql, Error: $e');
    rethrow;
  }
  }

  /// 执行更新
  Future<int> update(String sql, [List<Object?>? values]) async {
  final conn = await connect();
  try {
    _logger.fine('Executing update: $sql');
    final result = await conn.query(sql, values);
    return result.affectedRows ?? 0;
  } catch (e) {
    _logger.severe('Update failed: $sql, Error: $e');
    rethrow;
  }
  }

  /// 执行删除
  Future<int> delete(String sql, [List<Object?>? values]) async {
  final conn = await connect();
  try {
    _logger.fine('Executing delete: $sql');
    final result = await conn.query(sql, values);
    return result.affectedRows ?? 0;
  } catch (e) {
    _logger.severe('Delete failed: $sql, Error: $e');
    rethrow;
  }
  }

  /// 开始事务
  Future<void> startTransaction() async {
    return await _transactionLock.synchronized(() async {
      if (_inTransaction) {
        throw StateError('Transaction already in progress');
      }
      final conn = await connect();
      await conn.query('START TRANSACTION');
      _inTransaction = true;
      _logger.fine('Transaction started');
    });
  }

  /// 提交事务
  Future<void> commit() async {
    return await _transactionLock.synchronized(() async {
      if (!_inTransaction) {
        throw StateError('No transaction in progress');
      }
      final conn = await connect();
      await conn.query('COMMIT');
      _inTransaction = false;
      _logger.fine('Transaction committed');
    });
  }

  /// 回滚事务
  Future<void> rollback() async {
    return await _transactionLock.synchronized(() async {
      if (!_inTransaction) {
        throw StateError('No transaction in progress');
      }
      final conn = await connect();
      await conn.query('ROLLBACK');
      _inTransaction = false;
      _logger.fine('Transaction rolled back');
    });
  }

  /// 执行事务
  Future<T> transaction<T>(Future<T> Function() operation) async {
    return await _transactionLock.synchronized(() async {
      if (_inTransaction) {
        throw StateError('Nested transactions are not supported');
      }
      
      await startTransaction();
      try {
        final result = await operation();
        await commit();
        return result;
      } catch (e) {
        try {
          await rollback();
        } catch (rollbackError) {
          _logger.severe('Failed to rollback transaction: $rollbackError');
        }
        rethrow;
      }
    });
  }

  /// 测试数据库连接
  Future<bool> testConnection() async {
  try {
    await query('SELECT 1 as test');
    _logger.info('Database connection test successful');
    return true;
  } catch (e) {
    _logger.severe('Database connection test failed: $e');
    return false;
  }
  }

  /// 关闭连接
  Future<void> close() async {
    return await _connectionLock.synchronized(() async {
      if (_inTransaction) {
        _logger.warning('Closing connection while transaction is active, rolling back');
        try {
          await rollback();
        } catch (e) {
          _logger.severe('Failed to rollback transaction during close: $e');
        }
      }
      
      await _closeConnection();
      _logger.info('Database connection closed');
    });
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
}
