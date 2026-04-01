import 'dart:async';
import 'package:test/test.dart';
import 'package:flutter_skill/src/skill_server.dart';
import 'package:flutter_skill/src/skill_client.dart';
import 'package:flutter_skill/src/server_registry.dart';
import 'package:flutter_skill/src/drivers/app_driver.dart';

/// Minimal mock driver for testing.
class _MockDriver implements AppDriver {
  @override
  String get frameworkName => 'mock';

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<Map<String, dynamic>> tap(
      {String? key, String? text, String? ref}) async =>
      {'success': true, 'tapped': key ?? text};

  @override
  Future<Map<String, dynamic>> enterText(String? key, String text,
      {String? ref}) async =>
      {'success': true};

  @override
  Future<bool> swipe(
      {required String direction,
      double distance = 300,
      String? key}) async =>
      true;

  @override
  Future<List<dynamic>> getInteractiveElements(
      {bool includePositions = true}) async =>
      [];

  @override
  Future<Map<String, dynamic>> getInteractiveElementsStructured() async => {};

  @override
  Future<String?> takeScreenshot({double quality = 1.0, int? maxWidth}) async =>
      null;

  @override
  Future<List<String>> getLogs() async => [];

  @override
  Future<void> clearLogs() async {}

  @override
  Future<void> hotReload() async {}
}

void main() {
  group('SkillServer + SkillClient', () {
    late SkillServer server;

    setUp(() async {
      final driver = _MockDriver();
      server = SkillServer(
        id: 'test-server-${DateTime.now().millisecondsSinceEpoch}',
        driver: driver,
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      await ServerRegistry.unregister(server.id).catchError((_) {});
    });

    test('ping returns pong', () async {
      final client = SkillClient.byPort(server.port);
      final result = await client.call('ping', {});
      expect(result['pong'], isTrue);
    });

    test('inspect returns elements list', () async {
      final client = SkillClient.byPort(server.port);
      final result = await client.call('inspect', {});
      expect(result['elements'], isList);
    });

    test('tap returns success', () async {
      final client = SkillClient.byPort(server.port);
      final result = await client.call('tap', {'key': 'loginBtn'});
      expect(result['success'], isTrue);
    });

    test('unknown method returns error', () async {
      final client = SkillClient.byPort(server.port);
      expect(
        () => client.call('nonexistent_method', {}),
        throwsException,
      );
    });

    test('shutdown completes onShutdownRequested stream', () async {
      final shutdownFired = Completer<void>();
      server.onShutdownRequested.listen((_) {
        if (!shutdownFired.isCompleted) shutdownFired.complete();
      });
      final client = SkillClient.byPort(server.port);
      await client.call('shutdown', {});
      await shutdownFired.future.timeout(const Duration(seconds: 2));
      expect(shutdownFired.isCompleted, isTrue);
    });
  });
}
