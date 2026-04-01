import 'dart:convert';
import 'dart:io';
import '../drivers/flutter_driver.dart';
import '../skill_client.dart';
import 'output_format.dart';

Future<void> runInspect(List<String> args) async {
  // --server=<id>[,<id2>,...] — forward to named SkillServer instance(s)
  // --output=json|human       — output format
  final serverIds = _parseServerIds(args);
  final format = resolveOutputFormat(args);
  final cleanArgs =
      stripOutputFlag(args).where((a) => !a.startsWith('--server=')).toList();

  if (serverIds.isNotEmpty) {
    await _inspectViaServers(serverIds, format);
    return;
  }

  // Default behaviour: direct VM Service connection.
  String uri;
  try {
    uri = await FlutterSkillClient.resolveUri(cleanArgs);
  } catch (e) {
    print(e);
    exit(1);
  }

  final client = FlutterSkillClient(uri);

  try {
    await client.connect();
    final elements = await client.getInteractiveElements();

    if (format == OutputFormat.json) {
      print(jsonEncode({'elements': elements}));
    } else {
      // Print simplified tree for LLM consumption
      print('Interactive Elements:');
      if (elements.isEmpty) {
        print('(No interactive elements found)');
      } else {
        for (final e in elements) {
          _printElement(e);
        }
      }
    }
  } catch (e) {
    print('Error: $e');
    exit(1);
  } finally {
    await client.disconnect();
  }
}

/// Forward the inspect action to one or more named servers concurrently.
Future<void> _inspectViaServers(
    List<String> serverIds, OutputFormat format) async {
  final futures = serverIds.map((id) async {
    final stopwatch = Stopwatch()..start();
    try {
      final client = SkillClient.byId(id);
      final result = await client.call('inspect', {});
      stopwatch.stop();
      return _ServerResult(
          serverId: id,
          success: true,
          data: result,
          durationMs: stopwatch.elapsedMilliseconds);
    } catch (e) {
      stopwatch.stop();
      return _ServerResult(
          serverId: id,
          success: false,
          error: e.toString(),
          durationMs: stopwatch.elapsedMilliseconds);
    }
  });

  final results = await Future.wait(futures);

  if (format == OutputFormat.json) {
    print(jsonEncode(results.map((r) => r.toJson()).toList()));
    return;
  }

  for (final r in results) {
    if (!r.success) {
      print('[${r.serverId}] Error: ${r.error}');
      continue;
    }
    final elements = (r.data!['elements'] as List?) ?? [];
    print('[${r.serverId}] Interactive Elements (${r.durationMs}ms):');
    if (elements.isEmpty) {
      print('  (No interactive elements found)');
    } else {
      for (final e in elements) {
        _printElement(e, prefix: '  ');
      }
    }
  }
}

void _printElement(dynamic element, {String prefix = ''}) {
  if (element is! Map) return;

  // Try to extract useful info
  final type = element['type'] ?? 'Widget';
  final key = element['key'];
  final text = element['text'];
  final tooltip = element['tooltip'];

  var buffer = StringBuffer();
  buffer.write(prefix);
  buffer.write('- **$type**');

  if (key != null) buffer.write(' [Key: "$key"]');
  if (text != null && text.toString().isNotEmpty)
    buffer.write(' [Text: "$text"]');
  if (tooltip != null) buffer.write(' [Tooltip: "$tooltip"]');

  print(buffer.toString());

  // Recursively print children if any
  if (element.containsKey('children') && element['children'] is List) {
    for (final child in element['children']) {
      _printElement(child, prefix: '$prefix  ');
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Parse `--server=<id>[,<id2>,...]` from args and return the list of IDs.
List<String> _parseServerIds(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--server=')) {
      final value = arg.substring('--server='.length);
      return value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
  }
  return [];
}

/// Holds the outcome of a single per-server parallel action.
class _ServerResult {
  final String serverId;
  final bool success;
  final Map<String, dynamic>? data;
  final String? error;
  final int durationMs;

  const _ServerResult({
    required this.serverId,
    required this.success,
    this.data,
    this.error,
    required this.durationMs,
  });

  Map<String, dynamic> toJson() => {
        'server': serverId,
        'success': success,
        if (data != null) 'data': data,
        if (error != null) 'error': error,
        'duration_ms': durationMs,
      };
}
