import 'package:mysql1/mysql1.dart';

import 'abstract/i_connection_pool.dart';
import 'connection_pool.dart';
import 'connection_pool_config.dart';
import 'semaphore_connection_pool.dart';

/// 连接池工厂类 - 使用工厂模式创建不同类型的连接池
class ConnectionPoolFactory {
  
  /// 创建连接池
  /// 
  /// [type] 连接池类型
  /// [settings] MySQL连接设置
  /// [config] 连接池配置（可选）
  static IConnectionPool create({
    required ConnectionPoolType type,
    required ConnectionSettings settings,
    ConnectionPoolConfig? config,
  }) {
    final poolConfig = config ?? const ConnectionPoolConfig();
    
    switch (type) {
      case ConnectionPoolType.queueLock:
        return ConnectionPool(settings, poolConfig);
        
      case ConnectionPoolType.semaphore:
        return SemaphoreConnectionPool(settings, poolConfig);
    }
  }

  /// 创建队列+锁实现的连接池
  /// 适合低并发、稳定性要求高的场景
  static IConnectionPool createQueueLockPool({
    required ConnectionSettings settings,
    ConnectionPoolConfig? config,
  }) {
    return create(
      type: ConnectionPoolType.queueLock,
      settings: settings,
      config: config,
    );
  }

  /// 创建信号量实现的连接池
  /// 适合高并发、性能要求高的场景
  static IConnectionPool createSemaphorePool({
    required ConnectionSettings settings,
    ConnectionPoolConfig? config,
  }) {
    return create(
      type: ConnectionPoolType.semaphore,
      settings: settings,
      config: config,
    );
  }

  /// 根据并发需求自动选择最佳连接池类型
  /// 
  /// [settings] MySQL连接设置
  /// [expectedConcurrency] 预期并发数
  /// [config] 连接池配置（可选）
  static IConnectionPool createOptimal({
    required ConnectionSettings settings,
    required int expectedConcurrency,
    ConnectionPoolConfig? config,
  }) {
    // 根据并发数选择合适的连接池类型
    final type = expectedConcurrency > 50 
        ? ConnectionPoolType.semaphore 
        : ConnectionPoolType.queueLock;
        
    final optimizedConfig = config ?? _createOptimizedConfig(expectedConcurrency);
    
    return create(
      type: type,
      settings: settings,
      config: optimizedConfig,
    );
  }

  /// 创建高性能配置的连接池
  /// 针对高并发场景进行优化
  static IConnectionPool createHighPerformance({
    required ConnectionSettings settings,
    ConnectionPoolConfig? config,
  }) {
    final highPerfConfig = config ?? ConnectionPoolConfig(
      minConnections: 8,
      maxConnections: 25,
      connectionTimeout: 15000,    // 15秒
      maxIdleTime: 180000,         // 3分钟
      maxWaitTime: 5000,           // 5秒
      maxWaitingRequests: 300,     // 允许更多等待请求
      enableFastFail: false,       // 不启用快速失败
      validationInterval: 30000,   // 30秒验证一次
    );

    return create(
      type: ConnectionPoolType.semaphore,
      settings: settings,
      config: highPerfConfig,
    );
  }

  /// 创建资源节约配置的连接池
  /// 针对低资源环境进行优化
  static IConnectionPool createResourceSaving({
    required ConnectionSettings settings,
    ConnectionPoolConfig? config,
  }) {
    final savingConfig = config ?? ConnectionPoolConfig(
      minConnections: 1,
      maxConnections: 5,
      connectionTimeout: 30000,    // 30秒
      maxIdleTime: 600000,         // 10分钟
      maxWaitTime: 15000,          // 15秒
      maxWaitingRequests: 20,      // 较少的等待请求
      enableFastFail: false,
      validationInterval: 120000,  // 2分钟验证一次
    );

    return create(
      type: ConnectionPoolType.queueLock,
      settings: settings,
      config: savingConfig,
    );
  }

  /// 创建用于性能测试的连接池
  /// 
  /// [type] 连接池类型
  /// [settings] MySQL连接设置
  /// [concurrencyLevel] 并发等级（1-5，5为最高）
  static IConnectionPool createForBenchmark({
    required ConnectionPoolType type,
    required ConnectionSettings settings,
    int concurrencyLevel = 3,
  }) {
    assert(concurrencyLevel >= 1 && concurrencyLevel <= 5, 
           'Concurrency level must be between 1 and 5');

    final benchmarkConfig = ConnectionPoolConfig(
      minConnections: concurrencyLevel * 2,
      maxConnections: concurrencyLevel * 6,
      connectionTimeout: 10000,           // 10秒
      maxIdleTime: 120000,                // 2分钟
      maxWaitTime: 3000,                  // 3秒
      maxWaitingRequests: concurrencyLevel * 100,
      enableFastFail: false,
      validationInterval: 60000,          // 1分钟
    );

    return create(
      type: type,
      settings: settings,
      config: benchmarkConfig,
    );
  }

  /// 根据环境配置创建连接池
  /// 
  /// [settings] MySQL连接设置
  /// [environment] 环境类型（development, testing, staging, production）
  static IConnectionPool createForEnvironment({
    required ConnectionSettings settings,
    required String environment,
    ConnectionPoolConfig? config,
  }) {
    switch (environment.toLowerCase()) {
      case 'development':
        return createResourceSaving(settings: settings, config: config);
        
      case 'testing':
        return createForBenchmark(
          type: ConnectionPoolType.queueLock,
          settings: settings,
          concurrencyLevel: 2,
        );
        
      case 'staging':
        return createOptimal(
          settings: settings,
          expectedConcurrency: 100,
          config: config,
        );
        
      case 'production':
        return createHighPerformance(settings: settings, config: config);
        
      default:
        throw ArgumentError('Unknown environment: $environment');
    }
  }

  /// 根据预期并发数创建优化配置
  static ConnectionPoolConfig _createOptimizedConfig(int expectedConcurrency) {
    if (expectedConcurrency <= 10) {
      // 低并发配置
      return const ConnectionPoolConfig(
        minConnections: 1,
        maxConnections: 5,
        maxWaitTime: 10000,
        maxWaitingRequests: 20,
      );
    } else if (expectedConcurrency <= 50) {
      // 中等并发配置
      return const ConnectionPoolConfig(
        minConnections: 3,
        maxConnections: 10,
        maxWaitTime: 8000,
        maxWaitingRequests: 50,
      );
    } else if (expectedConcurrency <= 200) {
      // 高并发配置
      return const ConnectionPoolConfig(
        minConnections: 5,
        maxConnections: 15,
        maxWaitTime: 5000,
        maxWaitingRequests: 150,
      );
    } else {
      // 超高并发配置
      return const ConnectionPoolConfig(
        minConnections: 8,
        maxConnections: 25,
        maxWaitTime: 3000,
        maxWaitingRequests: 300,
        enableFastFail: true, // 启用快速失败以保护系统
      );
    }
  }

  /// 获取所有支持的连接池类型
  static List<ConnectionPoolType> getSupportedTypes() {
    return ConnectionPoolType.values;
  }

  /// 获取连接池类型的详细信息
  static Map<String, dynamic> getTypeInfo(ConnectionPoolType type) {
    switch (type) {
      case ConnectionPoolType.queueLock:
        return {
          'name': 'Queue + Lock',
          'description': '传统队列+锁实现 - 稳定可靠，适合低并发场景',
          'bestFor': ['低并发应用', '稳定性要求高', '资源受限环境'],
          'maxRecommendedConcurrency': 100,
          'advantages': ['稳定可靠', '资源消耗低', '易于调试'],
          'disadvantages': ['并发性能有限', '锁竞争较多'],
        };
        
      case ConnectionPoolType.semaphore:
        return {
          'name': 'Semaphore',
          'description': '信号量实现 - 高并发优化，适合高负载场景',
          'bestFor': ['高并发应用', '性能要求高', '微服务架构'],
          'maxRecommendedConcurrency': 1000,
          'advantages': ['并发性能优秀', '锁竞争少', '资源利用率高'],
          'disadvantages': ['实现复杂度稍高', '调试相对困难'],
        };
    }
  }
}