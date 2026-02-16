part of '../server.dart';

extension _AuthHandlers on FlutterMcpServer {
  /// Authentication tools
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleAuthTools(String name, Map<String, dynamic> args) async {
    if (name == 'auth_biometric') {
      final action = args['action'] as String? ?? '';
      if (action.isEmpty) return {"success": false, "error": "Missing required parameter: action (enroll|match|fail)"};
      final platform = await _detectSimulatorPlatform();
      String command;
      if (platform == 'ios') {
        // iOS biometric uses notifyutil via simctl spawn
        switch (action) {
          case 'enroll':
            command = 'xcrun simctl spawn booted notifyutil -s com.apple.BiometricKit.enrollmentChanged 1';
            break;
          case 'match':
            command = 'xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit.pearl.match';
            break;
          case 'fail':
            command = 'xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit.pearl.nomatch';
            break;
          default:
            return {"success": false, "error": "Invalid action: $action"};
        }
      } else {
        switch (action) {
          case 'enroll':
          case 'match':
            command = '${_findAdb()} -s emulator-5554 emu finger touch 1';
            break;
          case 'fail':
            command = '${_findAdb()} -s emulator-5554 emu finger touch 0';
            break;
          default:
            return {"success": false, "error": "Invalid action: $action"};
        }
      }
      try {
        final result = await Process.run('sh', ['-c', command]);
        return {"success": result.exitCode == 0, "platform": platform, "action": action};
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    if (name == 'auth_otp') {
      final secret = args['secret'] as String?;
      if (secret != null) {
        final digits = args['digits'] as int? ?? 6;
        final period = args['period'] as int? ?? 30;
        final code = _generateTotp(secret, digits, period);
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final validFor = period - (now % period);
        return {"code": code, "valid_for_seconds": validFor};
      }
      // Read clipboard
      final platform = await _detectSimulatorPlatform();
      try {
        if (platform == 'ios') {
          final result = await Process.run('xcrun', ['simctl', 'pbpaste', 'booted']);
          return {"clipboard": result.stdout.toString().trim(), "platform": "ios"};
        } else {
          final result = await Process.run(_findAdb(), ['shell', 'service', 'call', 'clipboard', '1']);
          return {"clipboard": result.stdout.toString().trim(), "platform": "android"};
        }
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    if (name == 'auth_deeplink') {
      final url = args['url'] as String;
      final platform = await _detectSimulatorPlatform();
      try {
        if (platform == 'web') {
          // For web/electron/tauri: navigate via eval
          final client = _getClient(args);
          if (client is BridgeDriver) {
            try {
              await client.callMethod('eval', {'expression': "window.location.href='$url'"});
              return {"success": true, "url": url, "platform": platform, "method": "eval"};
            } catch (_) {}
          }
          return {"success": false, "url": url, "platform": platform, "note": "Cannot open deep link on web platform without eval support"};
        }
        ProcessResult result;
        if (platform == 'ios') {
          result = await Process.run('xcrun', ['simctl', 'openurl', 'booted', url]);
        } else {
          result = await Process.run(_findAdb(), ['shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', url]);
        }
        return {"success": result.exitCode == 0, "url": url, "platform": platform};
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    // Recording tools

    if (name == 'auth_inject_session') {
      final token = args['token'] as String;
      final key = args['key'] as String? ?? 'auth_token';
      final storageType = args['storage_type'] as String? ?? 'shared_preferences';
      // Detect platform from active connection
      final platform = await _detectSimulatorPlatform();
      
      // For web/electron/tauri: inject via JavaScript
      if (storageType == 'cookie' || storageType == 'local_storage' || platform == 'web') {
        final js = storageType == 'cookie'
            ? "document.cookie='$key=$token; path=/'"
            : "window.localStorage.setItem('$key','$token')";
        // If connected to a bridge with eval support, execute directly
        final client = _getClient(args);
        if (client is BridgeDriver) {
          try {
            final evalResult = await client.callMethod('eval', {'expression': js});
            return {"success": true, "storage_type": storageType, "key": key, "platform": platform, "injected": true, "eval_result": evalResult};
          } catch (_) {
            // Fall back to returning snippet
          }
        }
        return {"success": true, "storage_type": storageType, "key": key, "js_snippet": js, "platform": platform, "note": "Execute this JS in your web app's console"};
      }
      // For shared_preferences on mobile: provide instruction
      try {
        return {"success": true, "storage_type": storageType, "key": key, "token": token, "platform": platform, "note": "Token prepared for injection. Use hot_restart to pick up changes."};
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    // Platform-agnostic tools that work on any connection type

    return null; // Not handled by this group
  }
}
