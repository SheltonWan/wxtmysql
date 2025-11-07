/// 连接池统计信息
class ConnectionPoolStats {
  final int totalConnections;
  final int activeConnections;
  final int idleConnections;
  final int waitingRequests;
  final int invalidConnections;
  final DateTime timestamp;

  ConnectionPoolStats({
    required this.totalConnections,
    required this.activeConnections,
    required this.idleConnections,
    required this.waitingRequests,
    required this.invalidConnections,
  }) : timestamp = DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'totalConnections': totalConnections,
      'activeConnections': activeConnections,
      'idleConnections': idleConnections,
      'waitingRequests': waitingRequests,
      'invalidConnections': invalidConnections,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  @override
  String toString() {
    return 'ConnectionPool(total: $totalConnections, active: $activeConnections, '
        'idle: $idleConnections, waiting: $waitingRequests, invalid: $invalidConnections)';
  }
}
