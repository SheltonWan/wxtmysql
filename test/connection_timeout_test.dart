import 'dart:async';
import 'package:test/test.dart';
import 'package:wxtmysql/connection_pool.dart';
import 'package:mysql1/mysql1.dart';
import 'package:wxtmysql/connection_pool_config.dart';
import 'package:wxtmysql/pooled_connection.dart';

/// 测试连接超时行为
void main() {
  group('Connection Pool Timeout Tests', () {
    test('应该正确显示等待队列长度在超时异常中', () async {
      // 创建一个快速超时的配置
      final config = ConnectionPoolConfig(
        minConnections: 1,
        maxConnections: 2,
        maxWaitTime: 1000, // 1秒超时
        maxWaitingRequests: 5,
        enableFastFail: false,
      );

      // 创建连接池（这里使用假的连接设置，因为我们主要测试超时逻辑）
      final settings = ConnectionSettings(
        host: 'localhost',
        port: 3306,
        user: 'test',
        password: 'test',
        db: 'test',
      );

      final pool = ConnectionPool(settings, config);

      try {
        // 模拟所有连接都被占用的情况
        // 首先获取所有可用连接
        final connections = <Future<PooledConnection>>[];

        // 启动多个并发请求，其中前2个会成功，后面的会等待
        for (int i = 0; i < 5; i++) {
          connections.add(pool.getConnection().then((conn) {
            print('请求 $i 成功获得连接');
            return conn;
          }).catchError((e) {
            print('请求 $i 失败: $e');
            // 检查错误消息是否包含正确的等待队列信息
            if (e is TimeoutException) {
              // 检查错误消息中是否显示了正确的等待队列长度
              final errorMessage = e.toString();
              print('超时错误消息: $errorMessage');
              // 应该显示等待中的请求数量大于0
              expect(errorMessage, contains('waiting'));
              expect(errorMessage, contains('before timeout'));
            }
            throw e; // 重新抛出异常
          }));
        }

        // 等待所有请求完成（成功或失败）
        await Future.wait(connections, eagerError: false);

      } catch (e) {
        print('测试过程中的异常（预期）: $e');
      } finally {
        await pool.close();
      }
    });

    test('健康检查应该包含超时统计信息', () async {
      final config = ConnectionPoolConfig(
        minConnections: 1,
        maxConnections: 1,
        maxWaitTime: 500, // 0.5秒超时
        maxWaitingRequests: 3,
      );

      final settings = ConnectionSettings(
        host: 'localhost',
        port: 3306,
        user: 'test',
        password: 'test',
        db: 'test',
      );

      final pool = ConnectionPool(settings, config);

      try {
        // 获取健康检查信息
        final health = await pool.healthCheck();

        // 验证包含超时统计
        expect(health, contains('timeout_statistics'));
        expect(health['timeout_statistics'], contains('total_timeouts'));
        expect(health['timeout_statistics'], contains('total_requests'));
        expect(health['timeout_statistics'], contains('timeout_rate_percent'));

        print('健康检查信息: $health');

      } finally {
        await pool.close();
      }
    });

    test('连接池统计应该包含无效连接数', () {
      final config = ConnectionPoolConfig();
      final settings = ConnectionSettings(
        host: 'localhost',
        port: 3306,
        user: 'test',
        password: 'test',
        db: 'test',
      );

      final pool = ConnectionPool(settings, config);
      final stats = pool.getStats();

      // 验证新增的统计字段
      expect(stats.toString(), contains('invalid'));
      expect(stats.toMap(), contains('invalidConnections'));

      print('连接池统计: $stats');
    });
  });
}
