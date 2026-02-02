import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// DTD 服务发现工具
///
/// 利用 Flutter 3.x 默认启动的 DTD 协议来发现 VM Service URI
class DtdServiceDiscovery {
  /// 通过 DTD 扫描发现 VM Service
  ///
  /// 策略:
  /// 1. 扫描端口范围，查找 DTD 服务
  /// 2. 连接到 DTD，查询 VM Service URI
  /// 3. 返回可用的 VM Service URI
  static Future<DiscoveryResult> discover({
    int portStart = 50000,
    int portEnd = 60000,
  }) async {
    print('🔍 扫描 DTD 服务 (端口范围: $portStart-$portEnd)...');

    // 1. 扫描 DTD 端口
    final dtdUris = await _scanDtdPorts(
      portStart: portStart,
      portEnd: portEnd,
    );

    if (dtdUris.isEmpty) {
      return DiscoveryResult(
        success: false,
        message: '未找到运行的 Flutter 应用（DTD 服务）',
      );
    }

    print('✅ 找到 ${dtdUris.length} 个 DTD 服务');

    // 2. 尝试从每个 DTD 获取 VM Service URI
    for (final dtdUri in dtdUris) {
      print('   检查 DTD: $dtdUri');

      final vmUri = await _queryVmServiceFromDtd(dtdUri);

      if (vmUri != null) {
        print('   ✅ 发现 VM Service: $vmUri');
        return DiscoveryResult(
          success: true,
          vmServiceUri: vmUri,
          dtdUri: dtdUri,
          discoveryMethod: 'dtd_query',
          message: '通过 DTD 发现 VM Service',
        );
      } else {
        print('   ⚠️  此 DTD 未启用 VM Service');
      }
    }

    // 3. 找到 DTD 但没有 VM Service
    return DiscoveryResult(
      success: false,
      dtdUri: dtdUris.first,
      discoveryMethod: 'dtd_only',
      message: '仅找到 DTD 服务，VM Service 未启用',
      suggestions: [
        'DTD 协议已连接，但 VM Service 未启动',
        '要启用完整功能，请重启应用:',
        'flutter run --vm-service-port=50000',
      ],
    );
  }

  /// 扫描端口范围，查找 DTD 服务
  static Future<List<String>> _scanDtdPorts({
    required int portStart,
    required int portEnd,
  }) async {
    final dtdUris = <String>[];
    final futures = <Future>[];

    for (var port = portStart; port <= portEnd; port++) {
      futures.add(_probeDtdPort(port).then((uri) {
        if (uri != null) {
          dtdUris.add(uri);
        }
      }));
    }

    await Future.wait(futures);
    return dtdUris;
  }

  /// 探测单个端口是否为 DTD 服务
  static Future<String?> _probeDtdPort(int port) async {
    try {
      // 尝试连接端口
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 100),
      );

      socket.destroy();

      // DTD 通常使用 WebSocket
      // 格式: ws://127.0.0.1:PORT/SECRET=/ws
      // 由于我们不知道 SECRET，先尝试常见路径
      final commonPaths = ['/ws', '/dtd', '/'];

      for (final path in commonPaths) {
        final uri = 'ws://127.0.0.1:$port$path';
        if (await _isDtdEndpoint(uri)) {
          return uri;
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// 验证是否为 DTD 端点
  static Future<bool> _isDtdEndpoint(String uri) async {
    try {
      final ws = await WebSocket.connect(uri)
          .timeout(const Duration(milliseconds: 200));

      // 发送 DTD 协议的探测请求
      ws.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'getVersion',
        'params': {},
      }));

      // 等待响应
      final responseStr = await ws.first.timeout(
        const Duration(milliseconds: 500),
      );

      final response = jsonDecode(responseStr as String);

      // 检查是否为 DTD 响应
      final isDtd = response['result']?['protocolVersion'] != null;

      await ws.close();
      return isDtd;
    } catch (e) {
      return false;
    }
  }

  /// 从 DTD 查询 VM Service URI
  static Future<String?> _queryVmServiceFromDtd(String dtdUri) async {
    try {
      final ws = await WebSocket.connect(dtdUri)
          .timeout(const Duration(milliseconds: 500));

      // DTD 可能提供 VM Service 信息的方法:
      // 1. getVM (如果支持)
      // 2. streamListen("VM") 然后接收事件
      // 3. 读取特定的服务注册信息

      // 尝试方法 1: getVM
      ws.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'getVM',
        'params': {},
      }));

      final responseStr = await ws.first.timeout(
        const Duration(milliseconds: 500),
      );

      final response = jsonDecode(responseStr as String);

      // 解析 VM Service URI（如果有）
      String? vmUri;

      // 可能的响应格式:
      // { "result": { "vmServiceUri": "http://..." } }
      if (response['result']?['vmServiceUri'] != null) {
        vmUri = response['result']['vmServiceUri'] as String;
      }

      await ws.close();
      return vmUri;
    } catch (e) {
      print('   查询失败: $e');
      return null;
    }
  }
}

/// 发现结果
class DiscoveryResult {
  final bool success;
  final String? vmServiceUri;
  final String? dtdUri;
  final String? discoveryMethod;
  final String message;
  final List<String> suggestions;

  DiscoveryResult({
    required this.success,
    this.vmServiceUri,
    this.dtdUri,
    this.discoveryMethod,
    required this.message,
    this.suggestions = const [],
  });

  Map<String, dynamic> toJson() => {
        'success': success,
        'vm_service_uri': vmServiceUri,
        'dtd_uri': dtdUri,
        'discovery_method': discoveryMethod,
        'message': message,
        if (suggestions.isNotEmpty) 'suggestions': suggestions,
      };

  @override
  String toString() => jsonEncode(toJson());
}

/// 使用示例
///
/// ```dart
/// // 自动发现 VM Service
/// final result = await DtdServiceDiscovery.discover();
///
/// if (result.success) {
///   print('找到 VM Service: ${result.vmServiceUri}');
///   final client = FlutterSkillClient(result.vmServiceUri!);
///   await client.connect();
/// } else {
///   print('警告: ${result.message}');
///   print('建议: ${result.suggestions.join("\n")}');
/// }
/// ```
