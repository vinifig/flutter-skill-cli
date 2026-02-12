import 'dart:io';
import 'package:flutter_skill/src/drivers/flutter_driver.dart';

Future<void> main() async {
  final uri = 'ws://127.0.0.1:63420/I8U6V_Mzdsg=/ws';
  final client = FlutterSkillClient(uri);

  print('══════════════════════════════════════════════════════');
  print('Flutter Skill MCP Tools Complete Test');
  print('══════════════════════════════════════════════════════');
  print('VM Service: $uri\n');

  try {
    // 1. Connection test
    print('1. Testing connection...');
    await client.connect();
    print('   ✅ Connected successfully\n');

    // 2. Get interactive elements
    print('2. Getting interactive elements (getInteractiveElements)...');
    final elements = await client.getInteractiveElements();
    print('   Found ${elements.length} interactive elements:');
    for (final elem in elements) {
      print('   - ${elem['type']}: ${elem['key']} ${elem['text'] != null ? '"${elem['text']}"' : ""}');
    }
    print('');

    // 3. Get Widget Tree
    print('3. Getting Widget Tree (getWidgetTree)...');
    final tree = await client.getWidgetTree(maxDepth: 5);
    final treeStr = tree.toString();
    print('   Widget Tree (first 5 levels):');
    print('   ${treeStr.substring(0, treeStr.length > 500 ? 500 : treeStr.length)}...\n');

    // 4. Get text content
    print('4. Getting all text content (getTextContent)...');
    final texts = await client.getTextContent();
    print('   Found ${texts.length} text elements:');
    for (final text in texts.take(5)) {
      print('   - "$text"');
    }
    if (texts.length > 5) print('   ...(total ${texts.length})');
    print('');

    // 5. Screenshot test
    print('5. Testing screenshot (takeScreenshot)...');
    try {
      final screenshot = await client.takeScreenshot();
      if (screenshot != null) {
        print('   ✅ Screenshot successful, size: ${screenshot.length} bytes');
        // Save screenshot (screenshot is base64 string)
        print('   💾 Screenshot data obtained\n');
      } else {
        print('   ⚠️  Screenshot returned null\n');
      }
    } catch (e) {
      print('   ❌ Screenshot failed: $e\n');
    }

    // 6. Get current route
    print('6. Getting current route (getCurrentRoute)...');
    try {
      final route = await client.getCurrentRoute();
      print('   Current route: $route\n');
    } catch (e) {
      print('   ❌ Failed to get route: $e\n');
    }

    // 7. Get navigation stack
    print('7. Getting navigation stack (getNavigationStack)...');
    try {
      final stack = await client.getNavigationStack();
      print('   Navigation stack: $stack\n');
    } catch (e) {
      print('   ❌ Failed to get navigation stack: $e\n');
    }

    // 8. Get logs
    print('8. Getting app logs (getLogs)...');
    try {
      final logs = await client.getLogs();
      print('   Log count: ${logs.length}');
      if (logs.isNotEmpty) {
        print('   Latest logs (first 3):');
        for (final log in logs.take(3)) {
          print('   - $log');
        }
      }
      print('');
    } catch (e) {
      print('   ❌ Failed to get logs: $e\n');
    }

    // 9. Get errors
    print('9. Getting runtime errors (getErrors)...');
    try {
      final errors = await client.getErrors();
      print('   Error count: ${errors.length}');
      if (errors.isNotEmpty) {
        print('   Error list:');
        for (final error in errors.take(3)) {
          print('   - $error');
        }
      } else {
        print('   ✅ No errors\n');
      }
    } catch (e) {
      print('   ❌ Failed to get errors: $e\n');
    }

    // 10. Get performance data
    print('10. Getting performance data (getPerformance)...');
    try {
      final perf = await client.getPerformance();
      print('   Performance data: $perf\n');
    } catch (e) {
      print('   ❌ Failed to get performance data: $e\n');
    }

    // 11. Interaction test - only test operations that don't affect UI
    if (elements.isNotEmpty) {
      final firstElem = elements.first;
      print('11. Interaction test (tap) - Testing tap...');
      print('   Tapping: ${firstElem['key']}');
      try {
        await client.tap(key: firstElem['key']);
        print('   ✅ Tap successful\n');
      } catch (e) {
        print('   ❌ Tap failed: $e\n');
      }
    }

    // 12. Hot Reload test
    print('12. Testing Hot Reload...');
    try {
      await client.hotReload();
      print('   ✅ Hot Reload successful\n');
    } catch (e) {
      print('   ❌ Hot Reload failed: $e\n');
    }

    print('══════════════════════════════════════════════════════');
    print('Test complete!');
    print('══════════════════════════════════════════════════════');
  } catch (e, stack) {
    print('❌ Error during testing: $e');
    print('Stack: $stack');
    exit(1);
  } finally {
    await client.disconnect();
    print('\n✅ Disconnected');
  }
}
