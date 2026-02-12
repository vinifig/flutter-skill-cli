/// Visual E2E test for iOS SDK - Maestro-style interactive testing.
///
/// Connects to the iOS native bridge running inside the simulator,
/// runs each operation, takes screenshots between steps.
///
/// Usage: dart run test/e2e/ios_visual_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_skill/src/bridge/bridge_protocol.dart';
import 'package:flutter_skill/src/discovery/bridge_discovery.dart';
import 'package:flutter_skill/src/drivers/bridge_driver.dart';

int _step = 0;
int _passed = 0;
int _failed = 0;

void stepHeader(String name) {
  _step++;
  print('\n${'━' * 60}');
  print(' Step $_step: $name');
  print('${'━' * 60}');
}

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    print('  ✅ $name${detail != null ? ' → $detail' : ''}');
  } else {
    _failed++;
    print('  ❌ $name${detail != null ? ' → $detail' : ''}');
  }
}

Future<void> saveScreenshot(BridgeDriver driver, String label) async {
  try {
    final b64 = await driver.takeScreenshot();
    if (b64 != null && b64.isNotEmpty) {
      final bytes = base64.decode(b64);
      final dir = Directory('test/e2e/screenshots');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/ios_step${_step}_$label.png');
      file.writeAsBytesSync(bytes);
      print('  📸 Screenshot saved: ${file.path} (${(bytes.length / 1024).toStringAsFixed(1)} KB)');
    }
  } catch (e) {
    print('  ⚠️  Screenshot failed: $e');
  }
}

Future<void> main() async {
  BridgeDriver? driver;

  try {
    // ── Step 1: Discovery ──
    stepHeader('Bridge Discovery');
    final discovered = await BridgeDiscovery.discoverAll(
      portStart: bridgeDefaultPort,
      portEnd: bridgeDefaultPort,
    );
    check('Found bridge service', discovered.isNotEmpty,
        discovered.isNotEmpty ? '${discovered.first}' : 'none found');

    if (discovered.isEmpty) {
      print('\n⛔ No bridge found. Is the iOS app running?');
      exit(1);
    }

    final info = discovered.first;
    check('Framework = ios-native', info.framework == 'ios-native', info.framework);
    check('Platform = ios', info.platform == 'ios', info.platform);
    check('Has inspect capability', info.capabilities.contains('inspect'));
    check('Has tap capability', info.capabilities.contains('tap'));
    check('Has screenshot capability', info.capabilities.contains('screenshot'));

    // ── Step 2: Connect ──
    stepHeader('Connect BridgeDriver');
    driver = BridgeDriver.fromInfo(info);
    await driver.connect();
    check('Connected', driver.isConnected);

    // ── Step 3: Initial Screenshot via Bridge ──
    stepHeader('Screenshot via Bridge');
    await saveScreenshot(driver, 'initial');

    // ── Step 4: Inspect UI ──
    stepHeader('Inspect Interactive Elements');
    final elements = await driver.getInteractiveElements();
    check('Got elements', elements.isNotEmpty, '${elements.length} elements');

    for (final e in elements) {
      final el = e as Map<String, dynamic>;
      final tag = el['type'] ?? el['tag'] ?? '?';
      final id = el['id'] ?? el['label'] ?? '';
      final text = (el['text'] as String? ?? '').replaceAll('\n', ' ');
      final shortText = text.length > 40 ? '${text.substring(0, 40)}...' : text;
      print('    [$tag] id=$id text="$shortText"');
    }

    final hasHelloBtn = elements.any((e) {
      final el = e as Map<String, dynamic>;
      return el['id'] == 'hello-btn' ||
          el['label'] == 'Say Hello' ||
          (el['text'] as String? ?? '').contains('Say Hello');
    });
    check('Found hello button', hasHelloBtn);

    final hasNameField = elements.any((e) {
      final el = e as Map<String, dynamic>;
      return el['id'] == 'name-field' ||
          el['type'] == 'text_field' ||
          (el['type'] as String? ?? '').contains('TextField') ||
          (el['tag'] as String? ?? '') == 'textfield';
    });
    check('Found name input', hasNameField);

    // ── Step 5: Tap "Say Hello" ──
    stepHeader('Tap "Say Hello" Button');
    final tapResult = await driver.tap(key: 'hello-btn');
    check('Tap returned', tapResult.isNotEmpty);
    await Future.delayed(const Duration(milliseconds: 500));

    // Check output text changed
    final outputAfterTap = await driver.getText(key: 'output');
    check('Output changed to "Hello clicked!"',
        outputAfterTap == 'Hello clicked!', '"$outputAfterTap"');
    await saveScreenshot(driver, 'after_tap_hello');

    // ── Step 6: Enter Text ──
    stepHeader('Enter Text in Name Field');
    final enterResult = await driver.enterText('name-field', 'Flutter Skill');
    check('Enter text returned', enterResult.isNotEmpty);
    await Future.delayed(const Duration(milliseconds: 500));
    await saveScreenshot(driver, 'after_enter_text');

    // ── Step 7: Tap Greet ──
    stepHeader('Tap "Greet" Button');
    final greetTap = await driver.tap(key: 'greet-btn');
    check('Greet tap returned', greetTap.isNotEmpty);
    await Future.delayed(const Duration(milliseconds: 500));

    final greetOutput = await driver.getText(key: 'output');
    check('Greeting shows response',
        greetOutput != null && greetOutput.startsWith('Hello'), '"$greetOutput"');
    await saveScreenshot(driver, 'after_greet');

    // ── Step 8: Tap Counter ──
    stepHeader('Tap Counter Button (3 times)');
    for (var i = 1; i <= 3; i++) {
      await driver.tap(key: 'count-btn');
      await Future.delayed(const Duration(milliseconds: 300));
    }
    await saveScreenshot(driver, 'after_count');

    // ── Step 9: Scroll ──
    stepHeader('Scroll Down');
    final scrollRes = await driver.scroll(direction: 'down', distance: 200);
    check('Scroll returned', scrollRes.isNotEmpty);
    await saveScreenshot(driver, 'after_scroll');

    // ── Step 10: Get Route ──
    stepHeader('Get Current Route');
    final route = await driver.getRoute();
    check('Got route', route != null && route.isNotEmpty, '"$route"');

    // ── Step 11: Logs ──
    stepHeader('Console Logs');
    final logs = await driver.getLogs();
    check('Got logs', true, '${logs.length} entries');
    if (logs.isNotEmpty) {
      for (final log in logs.take(5)) {
        print('    $log');
      }
      if (logs.length > 5) print('    ... and ${logs.length - 5} more');
    }

    // ── Step 12: Final screenshot ──
    stepHeader('Final State');
    await saveScreenshot(driver, 'final');

    // ── Summary ──
    print('\n${'═' * 60}');
    print(' iOS SDK E2E TEST RESULTS');
    print('${'═' * 60}');
    print(' ✅ Passed: $_passed');
    print(' ❌ Failed: $_failed');
    print(' 📸 Screenshots: test/e2e/screenshots/ios_*');
    print('${'═' * 60}');

    if (_failed == 0) {
      print('\n🎉 ALL TESTS PASSED!\n');
    } else {
      print('\n⚠️  Some tests failed.\n');
    }
  } catch (e, st) {
    print('\n💥 FATAL: $e');
    print(st);
    _failed++;
  } finally {
    await driver?.disconnect();
    exit(_failed > 0 ? 1 : 0);
  }
}
