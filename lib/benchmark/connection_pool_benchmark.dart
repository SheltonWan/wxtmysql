import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:mysql1/mysql1.dart';

import '../abstract/i_connection_pool.dart';
import '../connection_pool_config.dart';
import '../connection_pool_factory.dart';

/// 连接池性能基准测试工具
class ConnectionPoolBenchmark {
  final Logger _logger = Logger('ConnectionPoolBenchmark');
  final ConnectionSettings _settings;
  
  ConnectionPoolBenchmark(this._settings);

  /// 执行全面的性能对比测试
  /// 
  /// [testCases] 测试用例配置
  /// [iterations] 每个测试用例的迭代次数
  /// [warmupIterations] 预热迭代次数
  Future<Map<String, dynamic>> runComparisonBenchmark({
    List<BenchmarkTestCase>? testCases,
    int iterations = 1000,
    int warmupIterations = 100,
  }) async {
    final cases = testCases ?? _getDefaultTestCases();
    final results = <String, dynamic>{};
    
    _logger.info('Starting connection pool benchmark comparison');
    _logger.info('Test cases: ${cases.length}, Iterations: $iterations, Warmup: $warmupIterations');

    for (final testCase in cases) {
      _logger.info('Running test case: ${testCase.name}');
      
      final testResult = await _runSingleBenchmark(
        testCase: testCase,
        iterations: iterations,
        warmupIterations: warmupIterations,
      );
      
      results[testCase.name] = testResult;
    }

    // 生成对比报告
    final report = _generateComparisonReport(results);
    results['comparison_report'] = report;

    return results;
  }

  /// 执行单个连接池类型的基准测试
  Future<BenchmarkResult> runSinglePoolBenchmark({
    required ConnectionPoolType poolType,
    required int concurrency,
    required int iterations,
    int warmupIterations = 50,
    ConnectionPoolConfig? config,
  }) async {
    final pool = ConnectionPoolFactory.create(
      type: poolType,
      settings: _settings,
      config: config ?? _createBenchmarkConfig(concurrency),
    );

    try {
      await pool.initialize();
      
      // 预热
      if (warmupIterations > 0) {
        await _runConcurrentQueries(pool, warmupIterations ~/ 4, concurrency);
        await Future.delayed(Duration(milliseconds: 500)); // 稳定间隔
      }

      final stopwatch = Stopwatch()..start();
      await _runConcurrentQueries(pool, iterations, concurrency);
      stopwatch.stop();

      final stats = pool.getStats();
      final healthInfo = await pool.healthCheck();

      return BenchmarkResult(
        poolType: poolType,
        iterations: iterations,
        concurrency: concurrency,
        totalTimeMs: stopwatch.elapsedMilliseconds,
        averageTimeMs: stopwatch.elapsedMilliseconds / iterations,
        throughputQPS: (iterations * 1000) / stopwatch.elapsedMilliseconds,
        poolStats: stats,
        healthInfo: healthInfo,
      );
    } finally {
      await pool.close();
    }
  }

  /// 执行单个测试用例
  Future<Map<String, dynamic>> _runSingleBenchmark({
    required BenchmarkTestCase testCase,
    required int iterations,
    required int warmupIterations,
  }) async {
    final results = <String, BenchmarkResult>{};
    
    for (final poolType in ConnectionPoolType.values) {
      _logger.info('  Testing ${poolType.name} with ${testCase.concurrency} concurrency');
      
      final result = await runSinglePoolBenchmark(
        poolType: poolType,
        concurrency: testCase.concurrency,
        iterations: iterations,
        warmupIterations: warmupIterations,
        config: testCase.config,
      );
      
      results[poolType.name] = result;
    }

    return {
      'test_case': testCase.toMap(),
      'results': results.map((key, value) => MapEntry(key, value.toMap())),
      'winner': _determineWinner(results),
    };
  }

  /// 执行并发查询测试
  Future<void> _runConcurrentQueries(
    IConnectionPool pool,
    int totalQueries,
    int concurrency,
  ) async {
    final futures = <Future>[];
    final queriesPerWorker = totalQueries ~/ concurrency;
    
    for (int worker = 0; worker < concurrency; worker++) {
      futures.add(_runQueriesWorker(pool, queriesPerWorker));
    }
    
    await Future.wait(futures);
  }

  /// 单个工作线程执行查询
  Future<void> _runQueriesWorker(IConnectionPool pool, int queries) async {
    for (int i = 0; i < queries; i++) {
      final connection = await pool.getConnection();
      try {
        // 执行简单的测试查询
        await connection.connection.query('SELECT 1');
      } finally {
        await pool.returnConnection(connection);
      }
    }
  }

  /// 生成默认测试用例
  List<BenchmarkTestCase> _getDefaultTestCases() {
    return [
      BenchmarkTestCase(
        name: 'low_concurrency',
        description: '低并发场景 (5并发)',
        concurrency: 5,
        config: const ConnectionPoolConfig(
          minConnections: 2,
          maxConnections: 8,
          maxWaitTime: 5000,
        ),
      ),
      BenchmarkTestCase(
        name: 'medium_concurrency',
        description: '中等并发场景 (20并发)',
        concurrency: 20,
        config: const ConnectionPoolConfig(
          minConnections: 5,
          maxConnections: 15,
          maxWaitTime: 3000,
        ),
      ),
      BenchmarkTestCase(
        name: 'high_concurrency',
        description: '高并发场景 (50并发)',
        concurrency: 50,
        config: const ConnectionPoolConfig(
          minConnections: 8,
          maxConnections: 25,
          maxWaitTime: 2000,
        ),
      ),
      BenchmarkTestCase(
        name: 'extreme_concurrency',
        description: '极高并发场景 (100并发)',
        concurrency: 100,
        config: const ConnectionPoolConfig(
          minConnections: 10,
          maxConnections: 30,
          maxWaitTime: 1000,
          enableFastFail: true,
        ),
      ),
    ];
  }

  /// 创建基准测试配置
  ConnectionPoolConfig _createBenchmarkConfig(int concurrency) {
    return ConnectionPoolConfig(
      minConnections: max(2, concurrency ~/ 10),
      maxConnections: max(5, concurrency ~/ 2),
      maxWaitTime: 5000,
      maxWaitingRequests: concurrency * 2,
      connectionTimeout: 10000,
      maxIdleTime: 120000,
      validationInterval: 60000,
    );
  }

  /// 确定测试胜者
  Map<String, dynamic> _determineWinner(Map<String, BenchmarkResult> results) {
    if (results.isEmpty) return {'winner': 'none'};

    BenchmarkResult? bestThroughput;
    BenchmarkResult? bestLatency;

    for (final result in results.values) {
      if (bestThroughput == null || result.throughputQPS > bestThroughput.throughputQPS) {
        bestThroughput = result;
      }
      if (bestLatency == null || result.averageTimeMs < bestLatency.averageTimeMs) {
        bestLatency = result;
      }
    }

    return {
      'best_throughput': {
        'type': bestThroughput!.poolType.name,
        'qps': bestThroughput.throughputQPS,
      },
      'best_latency': {
        'type': bestLatency!.poolType.name,
        'avg_ms': bestLatency.averageTimeMs,
      },
      'overall_winner': bestThroughput.poolType.name,
    };
  }

  /// 生成对比报告
  Map<String, dynamic> _generateComparisonReport(Map<String, dynamic> results) {
    final summary = <String, dynamic>{};
    final recommendations = <String>[];

    for (final entry in results.entries) {
      if (entry.key == 'comparison_report') continue;
      
      final testCase = entry.value as Map<String, dynamic>;
      final winner = testCase['winner'] as Map<String, dynamic>;
      final concurrency = testCase['test_case']['concurrency'];
      
      summary[entry.key] = winner;
      
      // 生成建议
      if (concurrency <= 10) {
        recommendations.add('低并发场景 ($concurrency并发): 推荐使用 ${winner['overall_winner']}');
      } else if (concurrency <= 50) {
        recommendations.add('中并发场景 ($concurrency并发): 推荐使用 ${winner['overall_winner']}');
      } else {
        recommendations.add('高并发场景 ($concurrency并发): 推荐使用 ${winner['overall_winner']}');
      }
    }

    return {
      'summary': summary,
      'recommendations': recommendations,
      'conclusion': _generateConclusion(summary),
    };
  }

  /// 生成总结论
  String _generateConclusion(Map<String, dynamic> summary) {
    final semaphoreWins = summary.values
        .where((v) => v['overall_winner'] == 'semaphore')
        .length;
    final queueLockWins = summary.values
        .where((v) => v['overall_winner'] == 'queueLock')
        .length;

    if (semaphoreWins > queueLockWins) {
      return '信号量连接池在大多数场景下表现更优，建议用于生产环境';
    } else if (queueLockWins > semaphoreWins) {
      return '队列+锁连接池在大多数场景下表现更稳定，适合对稳定性要求高的环境';
    } else {
      return '两种连接池各有优势，建议根据具体并发需求选择';
    }
  }

  /// 保存基准测试报告到文件
  Future<void> saveBenchmarkReport(
    Map<String, dynamic> results,
    String filePath,
  ) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);

    final report = _formatReportAsMarkdown(results);
    await file.writeAsString(report);

    _logger.info('Benchmark report saved to: $filePath');
  }

  /// 格式化报告为 Markdown
  String _formatReportAsMarkdown(Map<String, dynamic> results) {
    final buffer = StringBuffer();
    final timestamp = DateTime.now().toIso8601String();

    buffer.writeln('# 连接池性能基准测试报告\n');
    buffer.writeln('**生成时间**: $timestamp\n');

    // 测试概览
    buffer.writeln('## 测试概览\n');
    final testCases = results.entries.where((e) => e.key != 'comparison_report');
    for (final entry in testCases) {
      final testCase = entry.value['test_case'];
      buffer.writeln('- **${entry.key}**: ${testCase['description']} (${testCase['concurrency']}并发)');
    }

    // 性能对比表
    buffer.writeln('\n## 性能对比结果\n');
    buffer.writeln('| 测试场景 | 连接池类型 | 吞吐量(QPS) | 平均延迟(ms) | 胜者 |');
    buffer.writeln('|---------|-----------|------------|-------------|------|');

    for (final entry in testCases) {
      final testName = entry.key;
      final testResults = entry.value['results'];
      final winner = entry.value['winner']['overall_winner'];

      for (final poolResult in testResults.entries) {
        final result = poolResult.value;
        final isWinner = poolResult.key == winner ? '🏆' : '';
        buffer.writeln('| $testName | ${poolResult.key} | ${result['throughputQPS'].toStringAsFixed(2)} | ${result['averageTimeMs'].toStringAsFixed(2)} | $isWinner |');
      }
    }

    // 建议和结论
    if (results['comparison_report'] != null) {
      final report = results['comparison_report'];
      
      buffer.writeln('\n## 建议\n');
      for (final recommendation in report['recommendations']) {
        buffer.writeln('- $recommendation');
      }

      buffer.writeln('\n## 结论\n');
      buffer.writeln(report['conclusion']);
    }

    return buffer.toString();
  }
}

/// 基准测试用例
class BenchmarkTestCase {
  final String name;
  final String description;
  final int concurrency;
  final ConnectionPoolConfig config;

  BenchmarkTestCase({
    required this.name,
    required this.description,
    required this.concurrency,
    required this.config,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'concurrency': concurrency,
      'config': {
        'min_connections': config.minConnections,
        'max_connections': config.maxConnections,
        'max_wait_time': config.maxWaitTime,
        'enable_fast_fail': config.enableFastFail,
      },
    };
  }
}

/// 基准测试结果
class BenchmarkResult {
  final ConnectionPoolType poolType;
  final int iterations;
  final int concurrency;
  final int totalTimeMs;
  final double averageTimeMs;
  final double throughputQPS;
  final dynamic poolStats;
  final Map<String, dynamic> healthInfo;

  BenchmarkResult({
    required this.poolType,
    required this.iterations,
    required this.concurrency,
    required this.totalTimeMs,
    required this.averageTimeMs,
    required this.throughputQPS,
    required this.poolStats,
    required this.healthInfo,
  });

  Map<String, dynamic> toMap() {
    return {
      'poolType': poolType.name,
      'iterations': iterations,
      'concurrency': concurrency,
      'totalTimeMs': totalTimeMs,
      'averageTimeMs': averageTimeMs,
      'throughputQPS': throughputQPS,
      'poolStats': poolStats.toMap(),
      'healthScore': healthInfo['health_score'] ?? 0,
    };
  }
}