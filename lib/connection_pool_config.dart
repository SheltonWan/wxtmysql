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

  /// 等待队列最大长度（防止内存溢出）
  final int maxWaitingRequests;

  /// 是否启用快速失败模式
  final bool enableFastFail;

  const ConnectionPoolConfig({
    this.minConnections = 2,
    this.maxConnections = 10,
    this.connectionTimeout = 30000, // 30秒
    this.maxIdleTime = 300000, // 5分钟
    this.validationQuery = 'SELECT 1',
    this.validationInterval = 60000, // 1分钟
    this.maxWaitTime = 10000, // 10秒
    this.maxWaitingRequests = 50, // 最大等待队列长度
    this.enableFastFail = false, // 是否启用快速失败
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
    if (maxWaitingRequests <= 0) {
      throw ArgumentError('maxWaitingRequests must be > 0');
    }
  }
}
