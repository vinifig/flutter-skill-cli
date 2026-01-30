import 'dart:io';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class FlutterSkillClient {
  final String wsUri;
  late VmService _service;
  late String _isolateId;

  FlutterSkillClient(this.wsUri);

  Future<void> connect() async {
    print('DEBUG: Connecting to $wsUri');
    _service = await vmServiceConnectUri(wsUri);
    print('DEBUG: Connected to VM Service');

    // Find the main isolate
    final vm = await _service.getVM();
    print('DEBUG: Got VM info');
    final isolates = vm.isolates;
    if (isolates == null || isolates.isEmpty) {
      throw Exception('No isolates found');
    }
    // Just pick the first one for now, usually the main one
    _isolateId = isolates.first.id!;
  }

  Future<void> disconnect() async {
    await _service.dispose();
  }

  Future<Map<String, dynamic>> _call(String method,
      [Map<String, dynamic>? args]) async {
    final response = await _service.callServiceExtension(
      method,
      isolateId: _isolateId,
      args: args,
    );
    return response.json ?? {};
  }

  Future<List<dynamic>> getInteractiveElements() async {
    final result = await _call('ext.flutter.flutter_skill.interactive');
    print('DEBUG: Interactive Result type: ${result.runtimeType}');
    print('DEBUG: Interactive Result: $result');

    // Result structure depends on marionette_flutter implementation.
    // Assuming it returns a list under a key like 'elements' or root list.
    if (result.containsKey('elements')) {
      return result['elements'] as List<dynamic>;
    }
    return []; // Fallback or empty
  }

  Future<void> tap({String? key, String? text}) async {
    if (key == null && text == null) {
      throw ArgumentError('Must provide key or text for tap');
    }
    await _call('ext.flutter.flutter_skill.tap', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
    });
  }

  Future<void> enterText(String key, String text) async {
    await _call('ext.flutter.flutter_skill.enterText', {
      'key': key,
      'text': text,
    });
  }

  Future<void> scrollTo({String? key, String? text}) async {
    await _call('ext.flutter.flutter_skill.scroll', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
    });
  }

  Future<String> takeScreenshot() async {
    // Standard VM Service has a screenshot method, but marionette might bundle it?
    // README says `take_screenshots` tool.
    // Let's assume it's an extension `.screenshot`
    // Or we can use `_service.getScreenshot(_isolateId)`?
    // README implies it captures "all active views".
    // Let's try the extension first.
    try {
      final result = await _call('ext.flutter.flutter_skill.screenshot');
      // Assuming return contains base64 image
      if (result.containsKey('image')) {
        return result['image'] as String;
      }
    } catch (e) {
      // Fallback
    }
    // Fallback to VM service screenshot
    // final res = await _service.getScreenshot(_isolateId);
    // return res.data!;
    return '';
  }

  Future<List<String>> getLogs() async {
    final result = await _call('ext.flutter.flutter_skill.logs');
    if (result.containsKey('logs')) {
      return (result['logs'] as List).cast<String>();
    }
    return [];
  }

  Future<void> hotReload() async {
    // Standard VM Service reload sources
    // We need to reload the isolate
    await _service.reloadSources(_isolateId);
    // Usually verify it somehow? But for now fire and forget is okay or we wait?
    // reloadSources returns a generic Success or Error.
  }

  Future<void> hotRestart() async {
    // Hot restart is usually a tool-level concept (flutter_tools), not strictly VM Service level.
    // However, we can try to use the extension provided by flutter tools if available?
    // Or we can rely on `flutter_tools` connecting to the same VM Service.
    // Actually `reloadSources` is Hot Reload.
    // "Hot Restart" destroys isolates.
    // Let's stick to Hot Reload for now as it's safer via VM service.
    // If we want FULL hot restart, we might need `ext.flutter.tools.hotRestart` if it exists.
    // For now, let's just implement reloadSources.
    await _service.reloadSources(_isolateId);
  }

  Future<Map<String, dynamic>> getLayoutTree() async {
    // Uses the standard Flutter Inspector extension
    // We try 'ext.flutter.inspector.getRootWidgetSummaryTree'
    try {
      // The inspector usually requires passing an 'objectGroup' name to manage memory.
      final groupName =
          'flutter_skill_${DateTime.now().millisecondsSinceEpoch}';
      final result =
          await _call('ext.flutter.inspector.getRootWidgetSummaryTree', {
        'objectGroup': groupName,
        // 'includeProperties': 'true', // Sometimes helpful but can be large
      });
      return result;
    } catch (e) {
      // Fallback or retry?
      rethrow;
    }
  }

  // Expose for server capability checking or similar if needed
  bool get isConnected => _isolateId.isNotEmpty;

  /// Helper to resolve URI from arguments or file
  static Future<String> resolveUri(List<String> args) async {
    if (args.isNotEmpty) {
      final arg = args[0];
      if (arg.startsWith('ws://') || arg.startsWith('http://')) {
        return arg;
      }
    }

    // Check for file
    final file = File('.flutter_skill_uri');
    if (await file.exists()) {
      final uri = (await file.readAsString()).trim();
      if (uri.isNotEmpty) {
        return uri;
      }
    }

    throw ArgumentError(
        'No URI provided and .flutter_skill_uri not found/empty. Run `dart run scripts/launch.dart` or provide URI as first argument.');
  }
}
