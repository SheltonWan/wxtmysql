import 'package:logging/logging.dart';
import 'package:mysql1/mysql1.dart';

import '../lib/abstract/i_connection_pool.dart';
import '../lib/connection_pool_config.dart';
import '../lib/connection_pool_factory.dart';
import '../lib/database_service.dart';

/// 健康检查测试脚本
Future<void> main() async {
  // 设置日志级别
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  print('🔍 测试连接池健康检查修复...\n');

  final settings = ConnectionSettings(
    host: 'gz-cynosdbmysql-grp-qo7yjmgh.sql.tencentcdb.com',
    port: 20599,
    user: 'your_username',  // 请替换为实际用户名
    password: 'your_password',  // 请替换为实际密码
    db: 'iwithyou',
  );

  try {
    // 测试1: 队列+锁连接池
    print('📊 测试队列+锁连接池健康检查...');
    await testPoolHealthCheck(ConnectionPoolType.queueLock, settings);

    print('\n' + '='*60 + '\n');

    // 测试2: 信号量连接池
    print('📊 测试信号量连接池健康检查...');
    await testPoolHealthCheck(ConnectionPoolType.semaphore, settings);

    print('\n' + '='*60 + '\n');

    // 测试3: DatabaseService 健康检查
    print('🏥 测试 DatabaseService 健康检查...');
    await testDatabaseServiceHealthCheck(settings);

  } catch (e, stackTrace) {
    print('❌ 测试失败: $e');
    print('堆栈跟踪: $stackTrace');
  }

  print('\n🎉 健康检查测试完成！');
}

/// 测试连接池健康检查
Future<void> testPoolHealthCheck(ConnectionPoolType type, ConnectionSettings settings) async {
  IConnectionPool? pool;
  
  try {
    pool = ConnectionPoolFactory.create(
      type: type,
      settings: settings,
      config: const ConnectionPoolConfig(
        minConnections: 2,
        maxConnections: 5,
        maxWaitTime: 5000,
      ),
    );

    print('创建 ${pool.typeName} 连接池...');
    await pool.initialize();

    // 执行健康检查
    final health = await pool.healthCheck();
    
    print('健康检查结果:');
    print('- 池状态: ${health['pool_status']}');
    print('- 健康评分: ${health['health_score']}');
    
    if (health['stats'] != null) {
      final stats = health['stats'];
      print('- 总连接数: ${stats['totalConnections']}');
      print('- 活跃连接: ${stats['activeConnections']}');
      print('- 等待请求: ${stats['waitingRequests']}');
    }

    // 如果有超时统计
    if (health['timeout_statistics'] != null) {
      final timeoutStats = health['timeout_statistics'];
      print('- 超时率: ${timeoutStats['timeout_rate_percent']}%');
    }

    print('✅ ${pool.typeName} 连接池健康检查成功');

  } catch (e) {
    print('❌ ${type.name} 连接池健康检查失败: $e');
  } finally {
    if (pool != null) {
      await pool.close();
    }
  }
}

/// 测试 DatabaseService 健康检查
Future<void> testDatabaseServiceHealthCheck(ConnectionSettings settings) async {
  try {
    // 重置现有实例
    await DatabaseService.reset();

    // 创建使用信号量连接池的服务
    final pool = ConnectionPoolFactory.createSemaphorePool(
      settings: settings,
      config: const ConnectionPoolConfig(
        minConnections: 2,
        maxConnections: 8,
        maxWaitTime: 5000,
      ),
    );

    final dbService = DatabaseService.withConnectionPool(pool);
    await dbService.initialize();

    print('DatabaseService 初始化完成...');

    // 执行健康检查
    final health = await dbService.healthCheck();
    
    print('\n🏥 DatabaseService 健康检查结果:');
    print('- 服务状态: ${health['service_status']}');
    print('- 数据库: ${health['database_info']}');
    print('- 连接池类型: ${health['pool_type']}');
    print('- 活跃事务: ${health['active_transactions']}');
    print('- 连接测试: ${health['connection_test']}');
    print('- 整体健康评分: ${health['overall_health_score']}/100');
    print('- 健康状态: ${health['health_status']}');
    
    if (health['recommendations'] != null) {
      print('- 建议:');
      for (final rec in health['recommendations']) {
        print('  • $rec');
      }
    }

    if (health['connection_test_error'] != null) {
      print('- 连接测试错误: ${health['connection_test_error']}');
    }

    print('\n✅ DatabaseService 健康检查成功');

    // 清理
    await dbService.close();

  } catch (e) {
    print('❌ DatabaseService 健康检查失败: $e');
  }
}