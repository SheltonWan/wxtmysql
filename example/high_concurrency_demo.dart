import 'dart:async';
import 'dart:math';
import 'package:wxtmysql/wxtmysql.dart';

/// 高并发连接池演示程序
void main() async {
  print('=== WXT MySQL 高并发连接池演示 ===\n');

  // 使用默认配置的数据库服务
  final dbService = DatabaseService.instance;
  
  // 也可以使用自定义配置创建（如果需要）:
  // final config = ConnectionPoolConfig(
  //   minConnections: 3,
  //   maxConnections: 10,
  //   connectionTimeout: 30000,
  //   maxIdleTime: 300000, // 5分钟
  //   maxWaitTime: 10000, // 10秒等待时间
  // );
  // final dbService = DatabaseService.withConfig(config);

  try {
    // 初始化连接池
    print('1. 初始化连接池...');
    await dbService.initialize();
    print('   连接池初始化完成');
    _printPoolStats(dbService);

    // 演示1: 高并发查询
    print('\n2. 高并发查询测试 (50个并发请求)...');
    await testHighConcurrencyQueries(dbService, 50);

    // 演示2: 连接池状态监控
    print('\n3. 连接池状态监控...');
    await demonstratePoolMonitoring(dbService);

    // 演示3: 事务处理
    print('\n4. 并发事务处理测试...');
    await testConcurrentTransactions(dbService);

    // 演示4: 连接池弹性伸缩
    print('\n5. 连接池弹性测试...');
    await testPoolElasticity(dbService);

  } catch (e) {
    print('演示过程中发生错误: $e');
  } finally {
    await dbService.close();
    print('\n=== 演示完成 ===');
  }
}

/// 测试高并发查询
Future<void> testHighConcurrencyQueries(DatabaseService dbService, int concurrency) async {
  final stopwatch = Stopwatch()..start();
  final futures = <Future<void>>[];

  for (int i = 0; i < concurrency; i++) {
    futures.add(
      Future.delayed(Duration(milliseconds: Random().nextInt(100)), () async {
        try {
          // 模拟不同类型的数据库操作
          final operationType = i % 4;
          switch (operationType) {
            case 0:
              await dbService.query('SELECT 1 as test, ? as id, NOW() as time', [i]);
              break;
            case 1:
              await dbService.query('SELECT CONNECTION_ID() as conn_id, ? as req_id', [i]);
              break;
            case 2:
              await dbService.query('SELECT SLEEP(0.01), ? as slow_query', [i]);
              break;
            case 3:
              await dbService.query('SELECT VERSION(), ? as version_query', [i]);
              break;
          }
          print('  请求 $i 完成');
        } catch (e) {
          print('  请求 $i 失败: $e');
        }
      })
    );
  }

  await Future.wait(futures);
  stopwatch.stop();

  print('   所有 $concurrency 个请求完成，耗时: ${stopwatch.elapsedMilliseconds}ms');
  print('   平均每请求: ${(stopwatch.elapsedMilliseconds / concurrency).toStringAsFixed(2)}ms');
  _printPoolStats(dbService);
}

/// 演示连接池监控
Future<void> demonstratePoolMonitoring(DatabaseService dbService) async {
  print('   连接池详细统计:');
  final detailedStats = dbService.getDetailedStats();
  detailedStats.forEach((key, value) {
    print('     $key: $value');
  });

  // 实时监控连接池状态变化
  print('\n   启动10个慢查询，观察连接池状态变化...');
  
  final futures = <Future<void>>[];
  for (int i = 0; i < 10; i++) {
    futures.add(
      Future.delayed(Duration(milliseconds: i * 100), () async {
        await dbService.query('SELECT SLEEP(0.5), ? as slow_id', [i]);
      })
    );
  }

  // 监控连接池状态
  final monitorTimer = Timer.periodic(Duration(milliseconds: 200), (timer) {
    print('     ${DateTime.now().millisecondsSinceEpoch}: ${dbService.poolStats}');
  });

  await Future.wait(futures);
  monitorTimer.cancel();
  
  print('   慢查询完成');
  _printPoolStats(dbService);
}

/// 测试并发事务
Future<void> testConcurrentTransactions(DatabaseService dbService) async {
  final futures = <Future<void>>[];
  
  for (int i = 0; i < 5; i++) {
    futures.add(
      Future.delayed(Duration(milliseconds: i * 50), () async {
        try {
          await dbService.transaction((tx) async {
            print('     事务 $i 开始');
            
            // 模拟事务内的多个操作
            await tx.query('SELECT 1 as tx_start, ? as tx_id', [i]);
            await Future.delayed(Duration(milliseconds: 200)); // 模拟业务逻辑
            await tx.query('SELECT 2 as tx_operation, ? as tx_id', [i]);
            await Future.delayed(Duration(milliseconds: 100));
            await tx.query('SELECT 3 as tx_end, ? as tx_id', [i]);
            
            print('     事务 $i 完成');
          });
        } catch (e) {
          print('     事务 $i 失败: $e');
        }
      })
    );
  }

  await Future.wait(futures);
  _printPoolStats(dbService);
}

/// 测试连接池弹性
Future<void> testPoolElasticity(DatabaseService dbService) async {
  print('   测试连接池在不同负载下的表现...');

  // 低负载
  print('     低负载测试 (2个请求)...');
  await testHighConcurrencyQueries(dbService, 2);
  await Future.delayed(Duration(seconds: 1));

  // 中等负载
  print('     中等负载测试 (8个请求)...');
  await testHighConcurrencyQueries(dbService, 8);
  await Future.delayed(Duration(seconds: 1));

  // 高负载
  print('     高负载测试 (15个请求)...');
  await testHighConcurrencyQueries(dbService, 15);
  await Future.delayed(Duration(seconds: 1));

  // 超负荷测试
  print('     超负荷测试 (25个请求)...');
  await testHighConcurrencyQueries(dbService, 25);
}

/// 打印连接池统计信息
void _printPoolStats(DatabaseService dbService) {
  final stats = dbService.poolStats;
  if (stats != null) {
    print('   📊 连接池状态: $stats');
  } else {
    print('   ❌ 连接池未初始化');
  }
}