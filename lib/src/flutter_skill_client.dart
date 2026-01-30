import 'dart:io';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class FlutterSkillClient {
  final String wsUri;
  VmService? _service;
  String? _isolateId;

  FlutterSkillClient(this.wsUri);

  /// Get the VM Service URI this client is connected to
  String get vmServiceUri => wsUri;

  Future<void> connect() async {
    print('DEBUG: Connecting to $wsUri');
    _service = await vmServiceConnectUri(wsUri);
    print('DEBUG: Connected to VM Service');

    final vm = await _service!.getVM();
    print('DEBUG: Got VM info');
    final isolates = vm.isolates;
    if (isolates == null || isolates.isEmpty) {
      throw Exception('No isolates found');
    }
    _isolateId = isolates.first.id!;
  }

  Future<void> disconnect() async {
    await _service?.dispose();
    _service = null;
    _isolateId = null;
  }

  Future<Map<String, dynamic>> _call(String method,
      [Map<String, dynamic>? args]) async {
    if (_service == null || _isolateId == null) {
      throw Exception('Not connected');
    }
    final response = await _service!.callServiceExtension(
      method,
      isolateId: _isolateId!,
      args: args,
    );
    return response.json ?? {};
  }

  // ==================== EXISTING METHODS ====================

  /// Tap an element. Returns result with success status.
  Future<Map<String, dynamic>> tap({String? key, String? text}) async {
    if (key == null && text == null) {
      throw ArgumentError('Must provide key or text for tap');
    }
    final result = await _call('ext.flutter.flutter_skill.tap', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
    });
    return result;
  }

  /// Enter text into a field. Returns result with success status.
  Future<Map<String, dynamic>> enterText(String key, String text) async {
    final result = await _call('ext.flutter.flutter_skill.enterText', {
      'key': key,
      'text': text,
    });
    return result;
  }

  /// Scroll to element. Returns result with success status.
  Future<Map<String, dynamic>> scrollTo({String? key, String? text}) async {
    final result = await _call('ext.flutter.flutter_skill.scroll', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
    });
    return result;
  }

  // ==================== UI INSPECTION ====================

  Future<Map<String, dynamic>> getWidgetTree({int maxDepth = 10}) async {
    final result = await _call('ext.flutter.flutter_skill.getWidgetTree', {
      'maxDepth': maxDepth.toString(),
    });
    return result['tree'] ?? {};
  }

  Future<Map<String, dynamic>?> getWidgetProperties(String key) async {
    final result =
        await _call('ext.flutter.flutter_skill.getWidgetProperties', {
      'key': key,
    });
    return result['properties'];
  }

  Future<List<dynamic>> getTextContent() async {
    final result = await _call('ext.flutter.flutter_skill.getTextContent');
    return result['texts'] ?? [];
  }

  Future<List<dynamic>> findByType(String type) async {
    final result = await _call('ext.flutter.flutter_skill.findByType', {
      'type': type,
    });
    return result['elements'] ?? [];
  }

  // ==================== MORE INTERACTIONS ====================

  Future<bool> longPress(
      {String? key, String? text, int duration = 500}) async {
    final result = await _call('ext.flutter.flutter_skill.longPress', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      'duration': duration.toString(),
    });
    return result['success'] == true;
  }

  Future<bool> swipe(
      {required String direction, double distance = 300, String? key}) async {
    final result = await _call('ext.flutter.flutter_skill.swipe', {
      'direction': direction,
      'distance': distance.toString(),
      if (key != null) 'key': key,
    });
    return result['success'] == true;
  }

  Future<bool> drag({required String fromKey, required String toKey}) async {
    final result = await _call('ext.flutter.flutter_skill.drag', {
      'fromKey': fromKey,
      'toKey': toKey,
    });
    return result['success'] == true;
  }

  Future<bool> doubleTap({String? key, String? text}) async {
    final result = await _call('ext.flutter.flutter_skill.doubleTap', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
    });
    return result['success'] == true;
  }

  // ==================== STATE & VALIDATION ====================

  Future<String?> getTextValue(String key) async {
    final result = await _call('ext.flutter.flutter_skill.getTextValue', {
      'key': key,
    });
    return result['value'];
  }

  Future<bool?> getCheckboxState(String key) async {
    final result = await _call('ext.flutter.flutter_skill.getCheckboxState', {
      'key': key,
    });
    return result['checked'];
  }

  Future<double?> getSliderValue(String key) async {
    final result = await _call('ext.flutter.flutter_skill.getSliderValue', {
      'key': key,
    });
    return result['value']?.toDouble();
  }

  Future<bool> waitForElement(
      {String? key, String? text, int timeout = 5000}) async {
    final result = await _call('ext.flutter.flutter_skill.waitForElement', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      'timeout': timeout.toString(),
    });
    return result['found'] == true;
  }

  Future<bool> waitForGone(
      {String? key, String? text, int timeout = 5000}) async {
    final result = await _call('ext.flutter.flutter_skill.waitForGone', {
      if (key != null) 'key': key,
      if (text != null) 'text': text,
      'timeout': timeout.toString(),
    });
    return result['gone'] == true;
  }

  // ==================== SCREENSHOT ====================

  Future<String?> takeScreenshot({double quality = 1.0, int? maxWidth}) async {
    final result = await _call('ext.flutter.flutter_skill.screenshot', {
      'quality': quality.toString(),
      if (maxWidth != null) 'maxWidth': maxWidth.toString(),
    });
    return result['image'];
  }

  Future<String?> takeRegionScreenshot(
      double x, double y, double width, double height) async {
    final result = await _call('ext.flutter.flutter_skill.screenshotRegion', {
      'x': x.toString(),
      'y': y.toString(),
      'width': width.toString(),
      'height': height.toString(),
    });
    return result['image'];
  }

  Future<String?> takeElementScreenshot(String key) async {
    final result = await _call('ext.flutter.flutter_skill.screenshotElement', {
      'key': key,
    });
    return result['image'];
  }

  // ==================== NAVIGATION ====================

  Future<String?> getCurrentRoute() async {
    final result = await _call('ext.flutter.flutter_skill.getCurrentRoute');
    return result['route'];
  }

  Future<bool> goBack() async {
    final result = await _call('ext.flutter.flutter_skill.goBack');
    return result['success'] == true;
  }

  Future<List<String>> getNavigationStack() async {
    final result = await _call('ext.flutter.flutter_skill.getNavigationStack');
    return (result['stack'] as List?)?.cast<String>() ?? [];
  }

  // ==================== DEBUG & LOGS ====================

  Future<List<String>> getLogs() async {
    final result = await _call('ext.flutter.flutter_skill.getLogs');
    return (result['logs'] as List?)?.cast<String>() ?? [];
  }

  Future<List<dynamic>> getErrors() async {
    final result = await _call('ext.flutter.flutter_skill.getErrors');
    return result['errors'] ?? [];
  }

  Future<void> clearLogs() async {
    await _call('ext.flutter.flutter_skill.clearLogs');
  }

  Future<Map<String, dynamic>> getPerformance() async {
    return await _call('ext.flutter.flutter_skill.getPerformance');
  }

  // ==================== COORDINATE-BASED ACTIONS ====================

  Future<Map<String, dynamic>> tapAt(double x, double y) async {
    return await _call('ext.flutter.flutter_skill.tapAt', {
      'x': x.toString(),
      'y': y.toString(),
    });
  }

  Future<Map<String, dynamic>> longPressAt(double x, double y,
      {int duration = 500}) async {
    return await _call('ext.flutter.flutter_skill.longPressAt', {
      'x': x.toString(),
      'y': y.toString(),
      'duration': duration.toString(),
    });
  }

  Future<Map<String, dynamic>> swipeCoordinates(
    double startX,
    double startY,
    double endX,
    double endY, {
    int duration = 300,
  }) async {
    return await _call('ext.flutter.flutter_skill.swipeCoordinates', {
      'startX': startX.toString(),
      'startY': startY.toString(),
      'endX': endX.toString(),
      'endY': endY.toString(),
      'duration': duration.toString(),
    });
  }

  /// Edge swipe from screen edge
  Future<Map<String, dynamic>> edgeSwipe({
    required String edge, // left, right, top, bottom
    required String direction, // up, down, left, right
    double distance = 200,
  }) async {
    return await _call('ext.flutter.flutter_skill.edgeSwipe', {
      'edge': edge,
      'direction': direction,
      'distance': distance.toString(),
    });
  }

  // ==================== PERFORMANCE & MEMORY ====================

  Future<Map<String, dynamic>> getFrameStats() async {
    try {
      final result = await _call('ext.flutter.flutter_skill.getFrameStats');
      return result;
    } catch (e) {
      // Fallback to basic stats if extension not available
      return {
        "message":
            "Frame stats not available. Ensure flutter_skill is properly initialized in the app.",
        "error": e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> getMemoryStats() async {
    if (_service == null || _isolateId == null) {
      throw Exception('Not connected');
    }

    try {
      final allocationProfile =
          await _service!.getAllocationProfile(_isolateId!);
      return {
        "heap_used": allocationProfile.memoryUsage?.heapUsage ?? 0,
        "heap_capacity": allocationProfile.memoryUsage?.heapCapacity ?? 0,
        "external": allocationProfile.memoryUsage?.externalUsage ?? 0,
      };
    } catch (e) {
      return {
        "message": "Memory stats retrieval failed",
        "error": e.toString(),
      };
    }
  }

  // ==================== ENHANCED INSPECTION ====================

  Future<List<dynamic>> getInteractiveElements(
      {bool includePositions = true}) async {
    final result = await _call('ext.flutter.flutter_skill.interactive', {
      'includePositions': includePositions.toString(),
    });

    if (result.containsKey('elements')) {
      return result['elements'] as List<dynamic>;
    }
    return [];
  }

  // ==================== EXISTING HELPERS ====================

  Future<void> hotReload() async {
    if (_service == null || _isolateId == null) {
      throw Exception('Not connected');
    }
    await _service!.reloadSources(_isolateId!);
  }

  Future<void> hotRestart() async {
    if (_service == null || _isolateId == null) {
      throw Exception('Not connected');
    }
    await _service!.reloadSources(_isolateId!);
  }

  Future<Map<String, dynamic>> getLayoutTree() async {
    try {
      final groupName =
          'flutter_skill_${DateTime.now().millisecondsSinceEpoch}';
      final result =
          await _call('ext.flutter.inspector.getRootWidgetSummaryTree', {
        'objectGroup': groupName,
      });
      return result;
    } catch (e) {
      rethrow;
    }
  }

  bool get isConnected => _service != null && _isolateId != null;

  static Future<String> resolveUri(List<String> args) async {
    if (args.isNotEmpty) {
      final arg = args[0];
      if (arg.startsWith('ws://') || arg.startsWith('http://')) {
        return arg;
      }
    }

    final file = File('.flutter_skill_uri');
    if (await file.exists()) {
      final uri = (await file.readAsString()).trim();
      if (uri.isNotEmpty) {
        return uri;
      }
    }

    throw ArgumentError(
        'No URI provided and .flutter_skill_uri not found/empty. Run `flutter_skill launch` or provide URI as first argument.');
  }
}
