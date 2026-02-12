/// End-to-end test for the Web SDK.
///
/// Tests the full flow: WebBridgeProxy → CDP → flutter-skill.js → DOM
///
/// Prerequisites:
///   Chrome must NOT already be running on CDP port 9222.
///
/// Usage:
///   dart run test/e2e/web_e2e_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_skill/src/bridge/bridge_protocol.dart';
import 'package:flutter_skill/src/bridge/web_bridge_proxy.dart';
import 'package:flutter_skill/src/discovery/bridge_discovery.dart';
import 'package:flutter_skill/src/drivers/bridge_driver.dart';

const int cdpPort = 9222;

int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

void check(String name, bool condition) {
  if (condition) {
    _passed++;
    print('  ✓ $name');
  } else {
    _failed++;
    _failures.add(name);
    print('  ✗ $name');
  }
}

Future<void> main() async {
  Process? chromeProcess;
  HttpServer? fileServer;
  WebBridgeProxy? proxy;
  BridgeDriver? driver;

  try {
    // ------------------------------------------------------------------
    // 1. Start a local file server for the test page
    // ------------------------------------------------------------------
    print('\n═══ Step 1: Start local file server ═══');
    fileServer = await HttpServer.bind('127.0.0.1', 0);
    final fileServerPort = fileServer.port;
    print('  File server on port $fileServerPort');

    fileServer.listen((request) async {
      final basePath = '${Directory.current.path}/test/e2e';
      var filePath = '$basePath${request.uri.path}';
      if (request.uri.path == '/') filePath = '$basePath/web_test_page.html';

      // Also serve sdks/web/flutter-skill.js
      if (request.uri.path.contains('flutter-skill.js')) {
        filePath = '${Directory.current.path}/sdks/web/flutter-skill.js';
      }

      final file = File(filePath);
      if (await file.exists()) {
        final ext = filePath.split('.').last;
        final contentType = ext == 'html'
            ? 'text/html'
            : ext == 'js'
                ? 'application/javascript'
                : 'text/plain';
        request.response
          ..statusCode = 200
          ..headers.set('Content-Type', '$contentType; charset=utf-8')
          ..add(await file.readAsBytes());
      } else {
        request.response
          ..statusCode = 404
          ..write('Not found: ${request.uri.path}');
      }
      await request.response.close();
    });

    // ------------------------------------------------------------------
    // 2. Launch Chrome with CDP enabled
    // ------------------------------------------------------------------
    print('\n═══ Step 2: Launch Chrome with CDP ═══');

    // Create a temp user data dir so we don't interfere with user's Chrome
    final tempDir = await Directory.systemTemp.createTemp('flutter_skill_e2e_');
    final chromePath =
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

    final testUrl =
        'http://127.0.0.1:$fileServerPort/web_test_page.html';

    chromeProcess = await Process.start(chromePath, [
      '--remote-debugging-port=$cdpPort',
      '--user-data-dir=${tempDir.path}',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-default-apps',
      '--disable-extensions',
      '--disable-sync',
      testUrl,
    ]);

    print('  Chrome PID: ${chromeProcess.pid}');

    // Wait for CDP to be ready
    print('  Waiting for CDP...');
    var cdpReady = false;
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 1);
        final req = await client.get('127.0.0.1', cdpPort, '/json');
        final resp = await req.close();
        if (resp.statusCode == 200) {
          cdpReady = true;
          client.close();
          break;
        }
        client.close();
      } catch (_) {}
    }

    if (!cdpReady) {
      print('  ✗ CDP did not become ready in 15 seconds');
      return;
    }
    print('  ✓ CDP is ready');

    // ------------------------------------------------------------------
    // 3. Start WebBridgeProxy
    // ------------------------------------------------------------------
    print('\n═══ Step 3: Start WebBridgeProxy ═══');
    proxy = WebBridgeProxy(cdpPort: cdpPort, bridgePort: bridgeDefaultPort);
    await proxy.start();
    print('  ✓ Proxy started on port $bridgeDefaultPort');

    // ------------------------------------------------------------------
    // 4. Test bridge discovery
    // ------------------------------------------------------------------
    print('\n═══ Step 4: Bridge Discovery ═══');
    final discovered = await BridgeDiscovery.discoverAll(
      portStart: bridgeDefaultPort,
      portEnd: bridgeDefaultPort, // only scan our port
    );
    check('Discovery found 1 app', discovered.length == 1);
    if (discovered.isNotEmpty) {
      final info = discovered.first;
      check('Framework is "web"', info.framework == 'web');
      check('Platform is "web"', info.platform == 'web');
      check('Has capabilities', info.capabilities.isNotEmpty);
      print('  Info: $info');
    }

    // ------------------------------------------------------------------
    // 5. Connect BridgeDriver
    // ------------------------------------------------------------------
    print('\n═══ Step 5: Connect BridgeDriver ═══');
    driver = BridgeDriver.fromInfo(discovered.first);
    await driver.connect();
    check('Driver connected', driver.isConnected);

    // ------------------------------------------------------------------
    // 6. Test: inspect
    // ------------------------------------------------------------------
    print('\n═══ Step 6: Inspect ═══');
    final elements = await driver.getInteractiveElements();
    check('Inspect returned elements', elements.isNotEmpty);
    print('  Found ${elements.length} elements');

    // Check for our test elements
    final hasHelloBtn = elements.any((e) {
      final el = e as Map<String, dynamic>;
      return el['testId'] == 'hello-btn' ||
          el['id'] == 'btn-hello' ||
          (el['text'] as String? ?? '').contains('Say Hello');
    });
    check('Found hello button', hasHelloBtn);

    final hasNameField = elements.any((e) {
      final el = e as Map<String, dynamic>;
      return el['testId'] == 'name-field' || el['id'] == 'name-input';
    });
    check('Found name input field', hasNameField);

    // ------------------------------------------------------------------
    // 7. Test: tap
    // ------------------------------------------------------------------
    print('\n═══ Step 7: Tap ═══');
    final tapResult = await driver.tap(key: 'hello-btn');
    check('Tap returned success', tapResult['success'] == true);

    // Verify the tap had an effect — check DOM via find_element
    await Future.delayed(const Duration(milliseconds: 200));
    final outputText = await driver.getText(key: 'output');
    check('Tap changed output text', outputText == 'Hello clicked!');
    print('  Output: $outputText');

    // ------------------------------------------------------------------
    // 8. Test: enter_text
    // ------------------------------------------------------------------
    print('\n═══ Step 8: Enter Text ═══');
    final enterResult =
        await driver.enterText('name-field', 'Flutter Skill');
    check('Enter text returned success', enterResult['success'] == true);

    // Tap greet button to verify text was entered
    await driver.tap(key: 'greet-btn');
    await Future.delayed(const Duration(milliseconds: 200));
    final greetOutput = await driver.getText(key: 'output');
    check(
        'Text entry worked (greet shows name)',
        greetOutput == 'Hello, Flutter Skill!');
    print('  Output: $greetOutput');

    // ------------------------------------------------------------------
    // 9. Test: find_element
    // ------------------------------------------------------------------
    print('\n═══ Step 9: Find Element ═══');
    final found = await driver.findElement(text: 'Count: 0');
    check('find_element found count button', found['found'] == true);

    final notFound = await driver.findElement(text: 'NONEXISTENT_ELEMENT_XYZ');
    check('find_element returns false for missing', notFound['found'] == false);

    // ------------------------------------------------------------------
    // 10. Test: screenshot
    // ------------------------------------------------------------------
    print('\n═══ Step 10: Screenshot ═══');
    final screenshot = await driver.takeScreenshot();
    check('Screenshot returned data', screenshot != null && screenshot.isNotEmpty);
    if (screenshot != null) {
      // Verify it's valid base64 PNG
      try {
        final bytes = base64.decode(screenshot);
        check('Screenshot is valid base64', bytes.length > 100);
        // PNG magic bytes: 89 50 4E 47
        check(
            'Screenshot is PNG',
            bytes.length > 4 &&
                bytes[0] == 0x89 &&
                bytes[1] == 0x50 &&
                bytes[2] == 0x4E &&
                bytes[3] == 0x47);
        print('  Screenshot size: ${bytes.length} bytes');
      } catch (e) {
        check('Screenshot base64 decode', false);
        print('  Error: $e');
      }
    }

    // ------------------------------------------------------------------
    // 11. Test: scroll
    // ------------------------------------------------------------------
    print('\n═══ Step 11: Scroll ═══');
    final scrollResult = await driver.scroll(direction: 'down', distance: 100);
    check('Scroll returned success', scrollResult['success'] == true);

    // ------------------------------------------------------------------
    // 12. Test: get_logs / clear_logs
    // ------------------------------------------------------------------
    print('\n═══ Step 12: Logs ═══');
    final logs = await driver.getLogs();
    check('get_logs returned list', logs is List);
    print('  Log count: ${logs.length}');

    await driver.clearLogs();
    final clearedLogs = await driver.getLogs();
    check('clear_logs empties logs', clearedLogs.isEmpty);

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    print('\n${'═' * 50}');
    print('Web SDK E2E Test Results: $_passed passed, $_failed failed');
    if (_failures.isNotEmpty) {
      print('Failures:');
      for (final f in _failures) {
        print('  - $f');
      }
    }
    print('${'═' * 50}');
  } catch (e, st) {
    print('\n✗ FATAL ERROR: $e');
    print(st);
    _failed++;
  } finally {
    // Cleanup
    print('\nCleaning up...');
    await driver?.disconnect();
    await proxy?.stop();
    await fileServer?.close(force: true);
    chromeProcess?.kill();
    // Give Chrome a moment to exit
    await Future.delayed(const Duration(seconds: 1));
    print('Done.');
    exit(_failed > 0 ? 1 : 0);
  }
}
