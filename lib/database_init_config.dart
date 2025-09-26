/// 数据库初始化配置
class DatabaseInitConfig {
  /// 是否确保数据库存在
  final bool ensureDatabase;
  
  /// 数据库字符集
  final String charset;
  
  /// 数据库排序规则
  final String collate;
  
  /// 连接超时时间（秒）
  final int connectionTimeout;
  
  /// 是否在数据库不存在时自动创建
  final bool autoCreate;
  
  /// 是否启用详细日志
  final bool verboseLogging;

  const DatabaseInitConfig({
    this.ensureDatabase = true,
    this.charset = 'utf8mb4',
    this.collate = 'utf8mb4_unicode_ci',
    this.connectionTimeout = 30,
    this.autoCreate = true,
    this.verboseLogging = false,
  });

  /// 为中文应用优化的配置
  static const DatabaseInitConfig chineseOptimized = DatabaseInitConfig(
    charset: 'utf8mb4',
    collate: 'utf8mb4_unicode_ci',
    verboseLogging: true,
  );

  /// 高性能配置（跳过数据库检查）
  static const DatabaseInitConfig highPerformance = DatabaseInitConfig(
    ensureDatabase: false,
    autoCreate: false,
    verboseLogging: false,
  );

  /// 开发环境配置
  static const DatabaseInitConfig development = DatabaseInitConfig(
    ensureDatabase: true,
    autoCreate: true,
    verboseLogging: true,
  );

  /// 生产环境配置
  static const DatabaseInitConfig production = DatabaseInitConfig(
    ensureDatabase: false,
    autoCreate: false,
    verboseLogging: false,
    connectionTimeout: 10,
  );

  @override
  String toString() {
    return 'DatabaseInitConfig('
           'ensureDatabase: $ensureDatabase, '
           'charset: $charset, '
           'collate: $collate, '
           'autoCreate: $autoCreate, '
           'timeout: ${connectionTimeout}s)';
  }
}

/// 数据库模式管理器
class DatabaseSchemaManager {
  
  /// 创建基础表结构的示例
  static const String createUsersTable = '''
    CREATE TABLE IF NOT EXISTS users (
      id BIGINT AUTO_INCREMENT PRIMARY KEY,
      name VARCHAR(100) NOT NULL,
      email VARCHAR(255) UNIQUE NOT NULL,
      password_hash VARCHAR(255) NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      INDEX idx_email (email),
      INDEX idx_created_at (created_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  ''';

  static const String createSessionsTable = '''
    CREATE TABLE IF NOT EXISTS sessions (
      id VARCHAR(128) PRIMARY KEY,
      user_id BIGINT NOT NULL,
      data TEXT,
      expires_at TIMESTAMP NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      INDEX idx_user_id (user_id),
      INDEX idx_expires_at (expires_at),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  ''';

  /// 获取预定义的表结构
  static List<String> getDefaultTables() {
    return [
      createUsersTable,
      createSessionsTable,
    ];
  }

  /// 检查表是否存在
  static String checkTableExists(String tableName) {
    return '''
      SELECT COUNT(*) as count 
      FROM INFORMATION_SCHEMA.TABLES 
      WHERE TABLE_SCHEMA = DATABASE() 
      AND TABLE_NAME = ?
    ''';
  }

  /// 获取表结构信息
  static String getTableInfo(String tableName) {
    return '''
      SELECT 
        COLUMN_NAME,
        DATA_TYPE,
        IS_NULLABLE,
        COLUMN_DEFAULT,
        EXTRA
      FROM INFORMATION_SCHEMA.COLUMNS 
      WHERE TABLE_SCHEMA = DATABASE() 
      AND TABLE_NAME = ?
      ORDER BY ORDINAL_POSITION
    ''';
  }
}