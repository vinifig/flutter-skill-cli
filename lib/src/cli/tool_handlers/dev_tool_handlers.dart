part of '../server.dart';

extension _DevToolHandlers on FlutterMcpServer {
  /// Developer tools (hot reload, pub search, indicators)
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleDevTools(String name, Map<String, dynamic> args) async {
    if (name == 'pub_search') {
      final query = args['query'];
      final url = Uri.parse('https://pub.dev/api/search?q=$query');
      final response = await http.get(url);
      if (response.statusCode != 200) throw Exception("Pub search failed");
      final json = jsonDecode(response.body);
      return json['packages'];
    }

    if (name == 'hot_reload') {
      final client = _getClient(args);
      _requireConnection(client);
      await client!.hotReload();
      return "Hot reload triggered";
    }

    if (name == 'hot_restart') {
      final client = _getClient(args);
      _requireConnection(client);
      final fc = _asFlutterClient(client!, 'hot_restart');
      await fc.hotRestart();
      return "Hot restart triggered";
    }

    if (name == 'enable_test_indicators') {
      final client = _getClient(args);
      _requireConnection(client);
      if (client is CdpDriver) {
        return {"success": true, "enabled": false, "message": "No-op for CDP"};
      }
      if (client is BridgeDriver) {
        final enabled = args['enabled'] ?? true;
        final style = args['style'] ?? 'standard';
        return await client.callMethod('enable_test_indicators', {'enabled': enabled, 'style': style});
      }
      final fc = _asFlutterClient(client!, 'enable_test_indicators');
      final enabled = args['enabled'] ?? true;
      final style = args['style'] ?? 'standard';

      if (enabled) {
        await fc.enableTestIndicators(style: style);
        return {
          "success": true,
          "enabled": true,
          "style": style,
          "message": "Test indicators enabled with $style style"
        };
      } else {
        await fc.disableTestIndicators();
        return {
          "success": true,
          "enabled": false,
          "message": "Test indicators disabled"
        };
      }
    }

    if (name == 'get_indicator_status') {
      final client = _getClient(args);
      _requireConnection(client);
      if (client is CdpDriver) {
        return {"enabled": false, "message": "No-op for CDP"};
      }
      if (client is BridgeDriver) {
        return await client.callMethod('get_indicator_status');
      }
      final fc = _asFlutterClient(client!, 'get_indicator_status');
      return await fc.getIndicatorStatus();
    }

    // Native platform interaction tools (no VM Service connection required)

    return null; // Not handled by this group
  }
}
