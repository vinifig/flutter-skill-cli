import 'dart:io';
import 'dart:async';
import 'dart:convert';

/// 协议类型
enum FlutterProtocol {
  /// VM Service 协议（完整功能）
  vmService,

  /// DTD 协议（基础功能）
  dtd,

  /// 无可用协议
  none,
}

/// 协议检测器
class ProtocolDetector {
  /// 检测 URI 使用的协议类型
  static FlutterProtocol detectFromUri(String uri) {
    // VM Service URI 格式:
    // http://127.0.0.1:50000/xxx=/
    // ws://127.0.0.1:50000/xxx=/ws
    if (uri.startsWith('http://') ||
        (uri.startsWith('ws://') && uri.contains('/ws') && !uri.contains('dtd'))) {
      return FlutterProtocol.vmService;
    }

    // DTD URI 格式:
    // ws://127.0.0.1:52049/xxx=/ws (通常端口不同)
    // 或明确包含 'dtd' 标识
    if (uri.startsWith('ws://') && uri.contains('=/ws')) {
      return FlutterProtocol.dtd;
    }

    return FlutterProtocol.none;
  }

  /// 扫描本地端口，检测可用协议
  static Future<Map<FlutterProtocol, List<String>>> scanAvailableProtocols({
    int portStart = 50000,
    int portEnd = 50100,
  }) async {
    final result = <FlutterProtocol, List<String>>{
      FlutterProtocol.vmService: [],
      FlutterProtocol.dtd: [],
    };

    final futures = <Future>[];

    for (var port = portStart; port <= portEnd; port++) {
      futures.add(_checkPort(port).then((uri) {
        if (uri != null) {
          final protocol = detectFromUri(uri);
          if (protocol != FlutterProtocol.none) {
            result[protocol]!.add(uri);
          }
        }
      }));
    }

    await Future.wait(futures);
    return result;
  }

  /// 检查特定端口是否有可用服务
  static Future<String?> _checkPort(int port) async {
    try {
      // 尝试连接端口
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 200),
      );

      // 尝试 HTTP 请求（VM Service）
      try {
        final request = await HttpClient()
            .getUrl(Uri.parse('http://127.0.0.1:$port'))
            .timeout(const Duration(milliseconds: 200));
        final response = await request.close();

        if (response.statusCode == 200) {
          // 读取响应体查找 VM Service URI
          final body = await response.transform(utf8.decoder).join();
          final uriMatch = RegExp(r'ws://[^\s"]+').firstMatch(body);
          if (uriMatch != null) {
            socket.destroy();
            return uriMatch.group(0);
          }
        }
      } catch (e) {
        // 不是 HTTP 服务，可能是 WebSocket
      }

      // 假设是 WebSocket 服务
      socket.destroy();
      return 'ws://127.0.0.1:$port/ws';
    } catch (e) {
      return null;
    }
  }

  /// 获取协议能力描述
  static Map<String, bool> getCapabilities(FlutterProtocol protocol) {
    switch (protocol) {
      case FlutterProtocol.vmService:
        return {
          'tap': true,
          'screenshot': true,
          'inspect': true,
          'hot_reload': true,
          'get_logs': true,
          'enter_text': true,
          'swipe': true,
        };

      case FlutterProtocol.dtd:
        return {
          'tap': false,
          'screenshot': false,
          'inspect': false,
          'hot_reload': true,
          'get_logs': true,
          'enter_text': false,
          'swipe': false,
        };

      case FlutterProtocol.none:
        return {};
    }
  }

  /// 生成友好的协议描述
  static String describeProtocol(FlutterProtocol protocol) {
    switch (protocol) {
      case FlutterProtocol.vmService:
        return 'VM Service (完整功能)';
      case FlutterProtocol.dtd:
        return 'DTD (基础功能: 热重载、日志)';
      case FlutterProtocol.none:
        return '无可用协议';
    }
  }
}
