import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'drivers/app_driver.dart';
import 'drivers/flutter_driver.dart';
import 'server_registry.dart';

/// A lightweight JSON-RPC 2.0 server over raw TCP (newline-delimited JSON)
/// that exposes AppDriver capabilities to local CLI clients.
///
/// Lifecycle:
///   1. Call [start] — binds a random free TCP port, registers in [ServerRegistry].
///   2. Clients connect and send newline-delimited JSON-RPC 2.0 requests.
///   3. Call [stop] — closes all connections, unregisters from [ServerRegistry].
class SkillServer {
  final String id;
  final AppDriver driver;
  final String projectPath;
  final String deviceId;

  ServerSocket? _tcpServer;
  ServerSocket? _unixServer;
  int? _port;
  final List<Socket> _connections = [];

  SkillServer({
    required this.id,
    required this.driver,
    this.projectPath = '',
    this.deviceId = '',
  });

  int get port => _port ?? 0;

  /// Start listening. Binds a random free TCP port and registers in the registry.
  Future<void> start() async {
    _tcpServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = _tcpServer!.port;

    _tcpServer!.listen(_handleConnection);

    // On Unix, also bind a Unix domain socket for lower-latency local IPC.
    final sockPath = ServerRegistry.unixSocketPath(id);
    if (sockPath != null) {
      try {
        // Remove stale socket file if present.
        final sockFile = File(sockPath);
        if (await sockFile.exists()) await sockFile.delete();

        _unixServer = await ServerSocket.bind(
          InternetAddress(sockPath, type: InternetAddressType.unix),
          0,
        );
        _unixServer!.listen(_handleConnection);
      } catch (_) {
        // Unix socket is optional — silently ignore failures.
      }
    }

    final entry = ServerEntry(
      id: id,
      port: _port!,
      pid: pid,
      projectPath: projectPath,
      deviceId: deviceId,
      vmServiceUri: _vmServiceUri(),
      startedAt: DateTime.now(),
    );
    await ServerRegistry.register(entry);
  }

  /// Stop the server and unregister from the registry.
  Future<void> stop() async {
    for (final conn in List<Socket>.from(_connections)) {
      await conn.close().catchError((_) => conn);
    }
    _connections.clear();
    await _tcpServer?.close();
    await _unixServer?.close();
    await ServerRegistry.unregister(id);
  }

  // ---------------------------------------------------------------------------
  // Connection handling
  // ---------------------------------------------------------------------------

  void _handleConnection(Socket socket) {
    _connections.add(socket);

    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _handleLine(socket, line),
          onDone: () => _connections.remove(socket),
          onError: (_) => _connections.remove(socket),
          cancelOnError: false,
        );
  }

  Future<void> _handleLine(Socket socket, String line) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    Map<String, dynamic> request;
    try {
      request = jsonDecode(trimmed) as Map<String, dynamic>;
    } catch (e) {
      _sendError(socket, null, -32700, 'Parse error: $e');
      return;
    }

    final id = request['id'];
    final method = request['method'] as String?;
    final params = (request['params'] as Map<String, dynamic>?) ?? {};

    if (method == null) {
      _sendError(socket, id, -32600, 'Invalid Request: missing method');
      return;
    }

    try {
      final result = await _dispatch(method, params);
      _sendResult(socket, id, result);
    } catch (e) {
      _sendError(socket, id, -32000, e.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Method dispatch — mirrors the MCP tool set
  //
  // Phase 1 implemented methods:
  //   tap, enter_text, swipe, inspect, screenshot, get_logs, clear_logs,
  //   hot_reload, hot_restart, scroll_to, ping, shutdown
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _dispatch(
      String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'tap':
        final result = await driver.tap(
          key: params['key'] as String?,
          text: params['text'] as String?,
          ref: params['ref'] as String?,
        );
        return result;

      case 'enter_text':
        final result = await driver.enterText(
          params['key'] as String?,
          params['text'] as String? ?? '',
          ref: params['ref'] as String?,
        );
        return result;

      case 'swipe':
        final success = await driver.swipe(
          direction: params['direction'] as String? ?? 'up',
          distance: (params['distance'] as num?)?.toDouble() ?? 300,
          key: params['key'] as String?,
        );
        return {'success': success};

      case 'inspect':
        final elements = await driver.getInteractiveElements(
          includePositions: (params['includePositions'] as bool?) ?? true,
        );
        return {'elements': elements};

      case 'screenshot':
        final image = await driver.takeScreenshot(
          quality: (params['quality'] as num?)?.toDouble() ?? 1.0,
          maxWidth: params['maxWidth'] as int?,
        );
        return {'image': image};

      case 'get_logs':
        final logs = await driver.getLogs();
        return {'logs': logs};

      case 'clear_logs':
        await driver.clearLogs();
        return {'success': true};

      case 'hot_reload':
        await driver.hotReload();
        return {'success': true};

      case 'hot_restart':
        // AppDriver does not have a dedicated hotRestart; use hotReload as fallback.
        await driver.hotReload();
        return {'success': true};

      case 'scroll_to':
        final success = await driver.swipe(
          direction: params['direction'] as String? ?? 'down',
          distance: (params['distance'] as num?)?.toDouble() ?? 300,
          key: params['key'] as String?,
        );
        return {'success': success};

      case 'shutdown':
        // Schedule stop after the response is sent so the client gets a reply.
        Future.microtask(() async {
          await stop();
          exit(0);
        });
        return {'success': true};

      case 'ping':
        return {'pong': true, 'server': id};

      default:
        throw Exception('Method not found: $method');
    }
  }

  // ---------------------------------------------------------------------------
  // JSON-RPC helpers
  // ---------------------------------------------------------------------------

  void _sendResult(Socket socket, dynamic id, Map<String, dynamic> result) {
    final response = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    });
    socket.writeln(response);
  }

  void _sendError(Socket socket, dynamic id, int code, String message) {
    final response = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });
    socket.writeln(response);
  }

  String _vmServiceUri() {
    if (driver is FlutterSkillClient) {
      return (driver as FlutterSkillClient).vmServiceUri;
    }
    return '';
  }
}
