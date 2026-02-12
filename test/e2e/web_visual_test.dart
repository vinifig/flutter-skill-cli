/// Visual E2E test for Web SDK - Maestro-style interactive testing.
///
/// Connects to the bridge proxy, runs each operation, takes screenshots
/// between steps, and outputs visual results.
///
/// Usage: dart run test/e2e/web_visual_test.dart
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
      final file = File('${dir.path}/web_step${_step}_$label.png');
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
      print('\n⛔ No bridge found. Is the proxy running?');
      exit(1);
    }

    final info = discovered.first;
    check('Framework = web', info.framework == 'web', info.framework);
    check('Has inspect capability', info.capabilities.contains('inspect'));
    check('Has tap capability', info.capabilities.contains('tap'));
    check('Has screenshot capability', info.capabilities.contains('screenshot'));

    // ── Step 2: Connect ──
    stepHeader('Connect BridgeDriver');
    driver = BridgeDriver.fromInfo(info);
    await driver.connect();
    check('Connected', driver.isConnected);

    // ── Step 3: Initial Screenshot ──
    stepHeader('Initial State Screenshot');
    await saveScreenshot(driver, 'initial');

    // ── Step 4: Inspect DOM ──
    stepHeader('Inspect Interactive Elements');
    final elements = await driver.getInteractiveElements();
    check('Got elements', elements.isNotEmpty, '${elements.length} elements');

    for (final e in elements) {
      final el = e as Map<String, dynamic>;
      final tag = el['tag'] ?? '?';
      final id = el['testId'] ?? el['id'] ?? '';
      final text = (el['text'] as String? ?? '').replaceAll('\n', ' ');
      final shortText = text.length > 40 ? '${text.substring(0, 40)}...' : text;
      print('    [$tag] id=$id text="$shortText"');
    }

    final hasHelloBtn = elements.any((e) =>
        (e as Map)['testId'] == 'hello-btn' || (e as Map)['id'] == 'btn-hello');
    check('Found hello button', hasHelloBtn);

    final hasNameField = elements.any((e) =>
        (e as Map)['testId'] == 'name-field' || (e as Map)['id'] == 'name-input');
    check('Found name input', hasNameField);

    // ── Step 5: Tap "Say Hello" button ──
    stepHeader('Tap "Say Hello" Button');
    final tapResult = await driver.tap(key: 'hello-btn');
    check('Tap success', tapResult['success'] == true);
    await Future.delayed(const Duration(milliseconds: 300));

    final outputAfterTap = await driver.getText(key: 'output');
    check('Output changed', outputAfterTap == 'Hello clicked!', '"$outputAfterTap"');
    await saveScreenshot(driver, 'after_tap_hello');

    // ── Step 6: Enter Text ──
    stepHeader('Enter Text in Name Field');
    final enterResult = await driver.enterText('name-field', 'Flutter Skill');
    check('Enter text success', enterResult['success'] == true);
    await Future.delayed(const Duration(milliseconds: 200));
    await saveScreenshot(driver, 'after_enter_text');

    // ── Step 7: Tap "Greet" button ──
    stepHeader('Tap "Greet" Button');
    final greetTap = await driver.tap(key: 'greet-btn');
    check('Greet tap success', greetTap['success'] == true);
    await Future.delayed(const Duration(milliseconds: 300));

    final greetOutput = await driver.getText(key: 'output');
    check('Greeting correct', greetOutput == 'Hello, Flutter Skill!', '"$greetOutput"');
    await saveScreenshot(driver, 'after_greet');

    // ── Step 8: Tap counter button ──
    stepHeader('Tap Counter Button (3 times)');
    for (var i = 1; i <= 3; i++) {
      final countTap = await driver.tap(key: 'count-btn');
      check('Count tap #$i', countTap['success'] == true);
      await Future.delayed(const Duration(milliseconds: 150));
    }
    // Find the count button text
    final countEl = await driver.findElement(key: 'count-btn');
    final countText = countEl['element']?['text'] ?? 'unknown';
    check('Counter = 3', countText == 'Count: 3', '"$countText"');
    await saveScreenshot(driver, 'after_count');

    // ── Step 9: Scroll ──
    stepHeader('Scroll Page');
    final scrollRes = await driver.scroll(direction: 'down', distance: 200);
    check('Scroll success', scrollRes['success'] == true);
    await saveScreenshot(driver, 'after_scroll');

    // ── Step 10: Logs ──
    stepHeader('Console Logs');
    final logs = await driver.getLogs();
    check('Got logs', logs is List, '${logs.length} entries');
    if (logs.isNotEmpty) {
      for (final log in logs.take(5)) {
        print('    $log');
      }
      if (logs.length > 5) print('    ... and ${logs.length - 5} more');
    }

    await driver.clearLogs();
    final cleared = await driver.getLogs();
    check('Logs cleared', cleared.isEmpty, '${cleared.length} after clear');

    // ── Step 11: Find Element by text ──
    stepHeader('Find Element by Text');
    final found = await driver.findElement(text: 'Hello, Flutter Skill!');
    check('Found greeting text', found['found'] == true);

    final notFound = await driver.findElement(text: 'NONEXISTENT_XYZ_123');
    check('Not found returns false', notFound['found'] == false);

    // ── Step 12: Final screenshot ──
    stepHeader('Final State');
    await saveScreenshot(driver, 'final');

    // ── Summary ──
    print('\n${'═' * 60}');
    print(' WEB SDK E2E TEST RESULTS');
    print('${'═' * 60}');
    print(' ✅ Passed: $_passed');
    print(' ❌ Failed: $_failed');
    print(' 📸 Screenshots: test/e2e/screenshots/');
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
