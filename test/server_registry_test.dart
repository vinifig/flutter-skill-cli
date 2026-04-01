import 'dart:io';
import 'package:test/test.dart';
import 'package:flutter_skill/src/server_registry.dart';

void main() {
  group('ServerRegistry', () {
    ServerEntry _makeEntry(String id, {int port = 9999}) => ServerEntry(
          id: id,
          port: port,
          pid: pid, // current process — guaranteed alive
          projectPath: '/tmp/test',
          deviceId: 'test-device',
          vmServiceUri: 'ws://127.0.0.1:$port/ws',
          startedAt: DateTime.now(),
        );

    test('register writes JSON file and get returns it', () async {
      final entry = _makeEntry('test-server-reg-${pid}');
      await ServerRegistry.register(entry);
      final loaded = await ServerRegistry.get(entry.id);
      expect(loaded, isNotNull);
      expect(loaded!.id, equals(entry.id));
      expect(loaded.port, equals(9999));
      // Cleanup
      await ServerRegistry.unregister(entry.id);
    });

    test('register rejects invalid id', () async {
      final entry = _makeEntry('invalid/id');
      expect(() => ServerRegistry.register(entry), throwsArgumentError);
    });

    test('register rejects path traversal id', () async {
      final entry = _makeEntry('../evil');
      expect(() => ServerRegistry.register(entry), throwsArgumentError);
    });

    test('get returns null for unknown id', () async {
      final result = await ServerRegistry.get('nonexistent-server-xyz');
      expect(result, isNull);
    });

    test('get returns null for invalid id', () async {
      final result = await ServerRegistry.get('../evil');
      expect(result, isNull);
    });

    test('unregister deletes entry', () async {
      final id = 'to-delete-${pid}';
      final entry = _makeEntry(id);
      await ServerRegistry.register(entry);
      expect(await ServerRegistry.get(id), isNotNull);
      await ServerRegistry.unregister(id);
      expect(await ServerRegistry.get(id), isNull);
    });

    test('listAll returns all registered entries', () async {
      final idA = 'server-a-${pid}';
      final idB = 'server-b-${pid}';
      await ServerRegistry.register(_makeEntry(idA, port: 9991));
      await ServerRegistry.register(_makeEntry(idB, port: 9992));
      final all = await ServerRegistry.listAll();
      expect(all.map((e) => e.id), containsAll([idA, idB]));
      // Cleanup
      await ServerRegistry.unregister(idA);
      await ServerRegistry.unregister(idB);
    });

    test('register throws on collision with live server', () async {
      final id = 'collision-test-${pid}';
      final entry = _makeEntry(id);
      await ServerRegistry.register(entry);
      // Registering same id again with live pid should throw StateError.
      expect(() => ServerRegistry.register(entry), throwsStateError);
      // Cleanup
      await ServerRegistry.unregister(id);
    });
  });
}
