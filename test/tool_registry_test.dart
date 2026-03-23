import 'package:test/test.dart';
import 'package:flutter_skill/src/engine/tool_registry.dart';

void main() {
  group('ToolRegistry — no connection (Gemini/Vertex AI limit fix)', () {
    late List<Map<String, dynamic>> noConnectionTools;

    setUp(() {
      noConnectionTools = ToolRegistry.getFilteredTools(
        hasCdp: false,
        hasBridge: false,
        hasFlutter: false,
        hasConnection: false,
      );
    });

    test('returns only connection tools when not connected', () {
      final names = noConnectionTools.map((t) => t['name'] as String).toSet();
      expect(names, equals(ToolRegistry.connectionOnlyTools));
    });

    test('stays under Gemini 128-tool limit when not connected', () {
      expect(
        noConnectionTools.length,
        lessThanOrEqualTo(ToolRegistry.geminiToolLimit),
        reason:
            'Vertex AI / Gemini rejects requests with > 128 tool declarations',
      );
    });

    test('includes all critical connection tools', () {
      final names = noConnectionTools.map((t) => t['name'] as String).toSet();
      for (final tool in [
        'connect_app',
        'connect_cdp',
        'connect_openclaw_browser',
        'connect_webmcp',
        'scan_and_connect',
        'launch_app',
      ]) {
        expect(names, contains(tool),
            reason: '$tool must be available before connecting');
      }
    });

    test('does not include CDP-only tools before connecting', () {
      final names = noConnectionTools.map((t) => t['name'] as String).toSet();
      for (final tool in [
        'snapshot',
        'act',
        'navigate',
        'eval',
        'get_cookies'
      ]) {
        expect(names, isNot(contains(tool)),
            reason: '$tool should only appear after CDP connection');
      }
    });

    test('does not include Flutter-only tools before connecting', () {
      final names = noConnectionTools.map((t) => t['name'] as String).toSet();
      for (final tool in ['hot_reload', 'get_widget_tree', 'find_by_type']) {
        expect(names, isNot(contains(tool)),
            reason: '$tool should only appear after Flutter connection');
      }
    });
  });

  group('ToolRegistry — CDP connection', () {
    late List<Map<String, dynamic>> cdpTools;

    setUp(() {
      cdpTools = ToolRegistry.getFilteredTools(
        hasCdp: true,
        hasBridge: false,
        hasFlutter: false,
        hasConnection: true,
      );
    });

    test('includes CDP tools after connecting', () {
      final names = cdpTools.map((t) => t['name'] as String).toSet();
      for (final tool in [
        'snapshot',
        'act',
        'navigate',
        'eval',
        'screenshot'
      ]) {
        expect(names, contains(tool),
            reason: '$tool must be available in CDP mode');
      }
    });

    test('excludes Flutter-only tools in CDP mode', () {
      final names = cdpTools.map((t) => t['name'] as String).toSet();
      for (final tool in ['hot_reload', 'get_widget_tree', 'find_by_type']) {
        expect(names, isNot(contains(tool)),
            reason: '$tool is Flutter-only and must not appear in CDP mode');
      }
    });

    test('excludes mobile-only tools in CDP mode', () {
      final names = cdpTools.map((t) => t['name'] as String).toSet();
      for (final tool in ['native_tap', 'native_swipe', 'auth_biometric']) {
        expect(names, isNot(contains(tool)),
            reason: '$tool is mobile-only and must not appear in CDP mode');
      }
    });
  });

  group('ToolRegistry — Flutter VM connection', () {
    late List<Map<String, dynamic>> flutterTools;

    setUp(() {
      flutterTools = ToolRegistry.getFilteredTools(
        hasCdp: false,
        hasBridge: false,
        hasFlutter: true,
        hasConnection: true,
      );
    });

    test('includes Flutter interaction tools after connecting', () {
      final names = flutterTools.map((t) => t['name'] as String).toSet();
      for (final tool in [
        'tap',
        'enter_text',
        'screenshot',
        'inspect',
        'hot_reload'
      ]) {
        expect(names, contains(tool),
            reason: '$tool must be available in Flutter mode');
      }
    });

    test('excludes CDP-only tools in Flutter mode', () {
      final names = flutterTools.map((t) => t['name'] as String).toSet();
      for (final tool in [
        'act',
        'navigate',
        'get_cookies',
        'get_tabs',
        'new_tab'
      ]) {
        expect(names, isNot(contains(tool)),
            reason: '$tool is CDP-only and must not appear in Flutter mode');
      }
    });
  });

  group('ToolRegistry — new connect tools registered', () {
    test('connect_openclaw_browser is in the full tool list', () {
      final all = ToolRegistry.getAllToolDefinitions();
      final names = all.map((t) => t['name'] as String).toSet();
      expect(names, contains('connect_openclaw_browser'));
    });

    test('connect_webmcp is in the full tool list', () {
      final all = ToolRegistry.getAllToolDefinitions();
      final names = all.map((t) => t['name'] as String).toSet();
      expect(names, contains('connect_webmcp'));
    });

    test('connect_openclaw_browser appears before connecting', () {
      final noConn = ToolRegistry.getFilteredTools(
        hasCdp: false,
        hasBridge: false,
        hasFlutter: false,
        hasConnection: false,
      );
      final names = noConn.map((t) => t['name'] as String).toSet();
      expect(names, contains('connect_openclaw_browser'));
    });

    test('connect_webmcp appears before connecting', () {
      final noConn = ToolRegistry.getFilteredTools(
        hasCdp: false,
        hasBridge: false,
        hasFlutter: false,
        hasConnection: false,
      );
      final names = noConn.map((t) => t['name'] as String).toSet();
      expect(names, contains('connect_webmcp'));
    });
  });

  group('ToolRegistry — total tool count sanity', () {
    test('full tool list has at least 180 tools', () {
      final all = ToolRegistry.getAllToolDefinitions();
      expect(all.length, greaterThanOrEqualTo(180));
    });

    test('no duplicate tool names in full list', () {
      final all = ToolRegistry.getAllToolDefinitions();
      final names = all.map((t) => t['name'] as String).toList();
      final unique = names.toSet();
      expect(
        names.length,
        equals(unique.length),
        reason:
            'Duplicate tool names: ${names.where((n) => names.where((x) => x == n).length > 1).toSet()}',
      );
    });

    test('connectionOnlyTools are all present in full list', () {
      final all = ToolRegistry.getAllToolDefinitions();
      final allNames = all.map((t) => t['name'] as String).toSet();
      for (final tool in ToolRegistry.connectionOnlyTools) {
        expect(allNames, contains(tool),
            reason:
                '$tool is in connectionOnlyTools but missing from full list');
      }
    });
  });

  group('ToolRegistry — idb and notifications/tools/list_changed', () {
    test('idb_describe is in the full tool list', () {
      final all = ToolRegistry.getAllToolDefinitions();
      final names = all.map((t) => t['name'] as String).toSet();
      expect(names, contains('idb_describe'));
    });

    test('idb_describe appears before connecting (connectionOnlyTools)', () {
      expect(ToolRegistry.connectionOnlyTools, contains('idb_describe'));
      final noConn = ToolRegistry.getFilteredTools(
        hasCdp: false,
        hasBridge: false,
        hasFlutter: false,
        hasConnection: false,
      );
      final names = noConn.map((t) => t['name'] as String).toSet();
      expect(names, contains('idb_describe'));
    });

    test('native_list_simulators appears before connecting', () {
      expect(
          ToolRegistry.connectionOnlyTools, contains('native_list_simulators'));
      final noConn = ToolRegistry.getFilteredTools(
        hasCdp: false,
        hasBridge: false,
        hasFlutter: false,
        hasConnection: false,
      );
      final names = noConn.map((t) => t['name'] as String).toSet();
      expect(names, contains('native_list_simulators'));
    });

    test('connectionOnlyTools still stays under Gemini 128-tool limit', () {
      expect(
        ToolRegistry.connectionOnlyTools.length,
        lessThanOrEqualTo(ToolRegistry.geminiToolLimit),
        reason: 'connectionOnlyTools set must never exceed the Gemini limit',
      );
    });

    test('native_tap is available in Flutter mode (uses idb as backend)', () {
      final tools = ToolRegistry.getFilteredTools(
        hasCdp: false,
        hasBridge: false,
        hasFlutter: true,
        hasConnection: true,
      );
      final names = tools.map((t) => t['name'] as String).toSet();
      expect(names, contains('native_tap'));
      expect(names, contains('native_swipe'));
      expect(names, contains('native_input_text'));
    });
  });
}
