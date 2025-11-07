import 'package:mysql1/mysql1.dart';

/// 池化连接包装类
class PooledConnection {
  final MySqlConnection connection;
  final DateTime createdAt;
  DateTime lastUsedAt;
  DateTime? lastValidatedAt;
  bool inUse;
  bool inTransaction;
  bool isInvalid; // 新增：标记连接是否无效

  PooledConnection(this.connection)
      : createdAt = DateTime.now(),
        lastUsedAt = DateTime.now(),
        inUse = false,
        inTransaction = false,
        isInvalid = false; // 初始化为有效连接

  /// 检查连接是否过期
  bool isExpired(int maxIdleTime) {
    return DateTime.now().difference(lastUsedAt).inMilliseconds > maxIdleTime;
  }

  /// 检查是否需要验证
  bool needsValidation(int validationInterval) {
    if (lastValidatedAt == null) return true;
    return DateTime.now().difference(lastValidatedAt!).inMilliseconds > validationInterval;
  }

  /// 标记为使用中
  void markInUse() {
    inUse = true;
    lastUsedAt = DateTime.now();
  }

  /// 标记为空闲
  void markIdle() {
    inUse = false;
    inTransaction = false;
    lastUsedAt = DateTime.now();
  }

  /// 标记验证时间
  void markValidated() {
    lastValidatedAt = DateTime.now();
  }
}
