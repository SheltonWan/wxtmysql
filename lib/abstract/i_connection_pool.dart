import 'dart:async';

import 'package:mysql1/mysql1.dart';

import '../connection_pool_config.dart';
import '../connection_pool_stats.dart';
import '../pooled_connection.dart';

/// 连接池类型枚举
enum ConnectionPoolType {
  /// 传统队列+锁实现
  queueLock,
  
  /// 信号量实现
  semaphore,
}

/// 连接池抽象接口
/// 定义了所有连接池实现必须提供的方法
abstract class IConnectionPool {
  /// 连接池类型
  ConnectionPoolType get type;

  /// 连接池配置
  ConnectionPoolConfig get config;

  /// 连接设置
  ConnectionSettings get settings;

  /// 是否已初始化
  bool get isInitialized;

  /// 是否正在关闭
  bool get isClosing;

  /// 初始化连接池
  Future<void> initialize();

  /// 获取连接
  /// 返回一个池化的连接对象
  Future<PooledConnection> getConnection();

  /// 归还连接到池中
  /// [pooledConnection] 要归还的连接
  Future<void> returnConnection(PooledConnection pooledConnection);

  /// 标记连接为无效
  /// [pooledConnection] 要标记为无效的连接
  Future<void> markConnectionInvalid(PooledConnection pooledConnection);

  /// 获取连接池统计信息
  ConnectionPoolStats getStats();

  /// 连接池健康检查
  /// 返回包含健康状态和详细信息的 Map
  Future<Map<String, dynamic>> healthCheck();

  /// 关闭连接池
  /// 关闭所有连接并清理资源
  Future<void> close();

  /// 获取连接池类型的字符串表示
  String get typeName => type.toString().split('.').last;

  /// 连接池描述信息
  String get description {
    switch (type) {
      case ConnectionPoolType.queueLock:
        return '传统队列+锁实现 - 稳定可靠，适合低并发场景';
      case ConnectionPoolType.semaphore:
        return '信号量实现 - 高并发优化，适合高负载场景';
    }
  }
}

/// 连接池性能指标接口
/// 扩展了基础统计信息，提供性能相关的指标
abstract class IConnectionPoolMetrics extends IConnectionPool {
  /// 获取详细的性能指标
  Map<String, dynamic> getPerformanceMetrics();

  /// 获取吞吐量统计（QPS）
  double get throughputQPS;

  /// 获取平均响应时间（毫秒）
  double get averageResponseTimeMs;

  /// 获取超时率（百分比）
  double get timeoutRatePercent;

  /// 重置性能统计
  void resetMetrics();
}

/// 连接池配置构建器
class ConnectionPoolConfigBuilder {
  int _minConnections = 2;
  int _maxConnections = 10;
  int _connectionTimeout = 30000;
  int _maxIdleTime = 300000;
  String _validationQuery = 'SELECT 1';
  int _validationInterval = 60000;
  int _maxWaitTime = 10000;
  int _maxWaitingRequests = 50;
  bool _enableFastFail = false;

  ConnectionPoolConfigBuilder setMinConnections(int value) {
    _minConnections = value;
    return this;
  }

  ConnectionPoolConfigBuilder setMaxConnections(int value) {
    _maxConnections = value;
    return this;
  }

  ConnectionPoolConfigBuilder setConnectionTimeout(int value) {
    _connectionTimeout = value;
    return this;
  }

  ConnectionPoolConfigBuilder setMaxIdleTime(int value) {
    _maxIdleTime = value;
    return this;
  }

  ConnectionPoolConfigBuilder setValidationQuery(String value) {
    _validationQuery = value;
    return this;
  }

  ConnectionPoolConfigBuilder setValidationInterval(int value) {
    _validationInterval = value;
    return this;
  }

  ConnectionPoolConfigBuilder setMaxWaitTime(int value) {
    _maxWaitTime = value;
    return this;
  }

  ConnectionPoolConfigBuilder setMaxWaitingRequests(int value) {
    _maxWaitingRequests = value;
    return this;
  }

  ConnectionPoolConfigBuilder enableFastFail([bool value = true]) {
    _enableFastFail = value;
    return this;
  }

  /// 构建配置对象
  Map<String, dynamic> buildAsMap() {
    return {
      'minConnections': _minConnections,
      'maxConnections': _maxConnections,
      'connectionTimeout': _connectionTimeout,
      'maxIdleTime': _maxIdleTime,
      'validationQuery': _validationQuery,
      'validationInterval': _validationInterval,
      'maxWaitTime': _maxWaitTime,
      'maxWaitingRequests': _maxWaitingRequests,
      'enableFastFail': _enableFastFail,
    };
  }

  /// 创建高并发优化配置
  static Map<String, dynamic> createHighConcurrencyConfig() {
    return ConnectionPoolConfigBuilder()
        .setMinConnections(5)
        .setMaxConnections(20)
        .setMaxWaitTime(5000)
        .setMaxWaitingRequests(200)
        .setConnectionTimeout(15000)
        .enableFastFail(false)
        .buildAsMap();
  }

  /// 创建低延迟优化配置
  static Map<String, dynamic> createLowLatencyConfig() {
    return ConnectionPoolConfigBuilder()
        .setMinConnections(8)
        .setMaxConnections(15)
        .setMaxWaitTime(3000)
        .setMaxWaitingRequests(50)
        .setConnectionTimeout(10000)
        .enableFastFail(true)
        .buildAsMap();
  }

  /// 创建资源节约配置
  static Map<String, dynamic> createResourceSavingConfig() {
    return ConnectionPoolConfigBuilder()
        .setMinConnections(1)
        .setMaxConnections(5)
        .setMaxWaitTime(15000)
        .setMaxWaitingRequests(20)
        .setConnectionTimeout(30000)
        .enableFastFail(false)
        .buildAsMap();
  }
}