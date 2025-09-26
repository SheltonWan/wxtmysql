/// 集中管理环境变量 Key，避免在代码中硬编码字符串。
class EnvKeys {
  EnvKeys._();

  // 数据库连接分散配置（dotenv 或系统环境变量）
  static const String dbHost = 'MYSQL_HOST';
  static const String dbPort = 'MYSQL_PORT';
  static const String dbName = 'MYSQL_DBNAME';
  static const String dbUser = 'MYSQL_USER';
  static const String dbPassword = 'MYSQL_PASSWORD';

  // 统一连接 URL（测试用）
  static const String databaseUrl = 'DATABASE_URL';
}
