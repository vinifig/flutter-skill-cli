part of '../server.dart';

extension _NativeHandlers on FlutterMcpServer {
  /// Native platform interaction tools
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleNativeTools(String name, Map<String, dynamic> args) async {
    if (name == 'native_screenshot') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
          "suggestions": [
            "Ensure an iOS Simulator or Android emulator is running",
            "If using a physical device, native tools are not yet supported",
          ],
        };
      }
      final saveToFile = args['save_to_file'] ?? true;
      final result = await driver.screenshot(saveToFile: saveToFile);
      return result.toJson();
    }

    if (name == 'native_tap') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }

      final toolCheck = await driver.checkToolAvailability();
      final missingTools =
          toolCheck.entries.where((e) => !e.value).map((e) => e.key).toList();
      if (missingTools.isNotEmpty) {
        return {
          "success": false,
          "error": {
            "code": "E502",
            "message": "Missing required tools: ${missingTools.join(', ')}",
          },
          "suggestions": driver.platform == NativePlatform.iosSimulator
              ? [
                  "Ensure Xcode command line tools are installed: xcode-select --install"
                ]
              : [
                  "Install Android platform tools: brew install android-platform-tools"
                ],
        };
      }

      final x = (args['x'] as num).toDouble();
      final y = (args['y'] as num).toDouble();
      final result = await driver.tap(x, y).timeout(
        const Duration(seconds: 15),
        onTimeout: () => NativeResult(success: false, message: 'native_tap timed out (15s) — check macOS Accessibility permissions'),
      );
      return result.toJson();
    }

    if (name == 'native_input_text') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      final text = args['text'] as String;
      final result = await driver.inputText(text).timeout(
        const Duration(seconds: 15),
        onTimeout: () => NativeResult(success: false, message: 'native_input_text timed out (15s) — check macOS Accessibility permissions'),
      );
      return result.toJson();
    }

    if (name == 'native_swipe') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      final startX = (args['start_x'] as num).toDouble();
      final startY = (args['start_y'] as num).toDouble();
      final endX = (args['end_x'] as num).toDouble();
      final endY = (args['end_y'] as num).toDouble();
      final duration = args['duration'] as int? ?? 300;
      final result =
          await driver.swipe(startX, startY, endX, endY, durationMs: duration).timeout(
        const Duration(seconds: 15),
        onTimeout: () => NativeResult(success: false, message: 'native_swipe timed out (15s) — check macOS Accessibility permissions'),
      );
      return result.toJson();
    }

    // Auth tools (system commands, no bridge connection required)

    return null; // Not handled by this group
  }
}
