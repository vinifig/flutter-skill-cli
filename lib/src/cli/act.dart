import 'dart:convert';
import 'dart:io';
import '../drivers/flutter_driver.dart';
import 'output_format.dart';

Future<void> runAct(List<String> args) async {
  // --server=<id>[,<id2>,...] — forward to named SkillServer instance(s)
  final serverIds = parseServerIds(args);
  final format = resolveOutputFormat(args);
  final effectiveArgs = stripOutputFormatFlag(args)
      .where((a) => !a.startsWith('--server='))
      .toList();

  if (serverIds.isNotEmpty) {
    await _actViaServers(serverIds, effectiveArgs, format);
    return;
  }

  String uri;
  int argOffset;

  // Check if first arg is a URI
  if (effectiveArgs.isNotEmpty &&
      (effectiveArgs[0].startsWith('ws://') ||
          effectiveArgs[0].startsWith('http://'))) {
    uri = effectiveArgs[0];
    argOffset = 1;
  } else {
    // Use auto-discovery (no need for .flutter_skill_uri file!)
    try {
      uri = await FlutterSkillClient.resolveUri([]);
      argOffset = 0;
    } catch (e) {
      print(e);
      exit(1);
    }
  }

  if (effectiveArgs.length <= argOffset) {
    print('Missing action argument');
    print('Usage: flutter_skill act [vm-uri] <action> <params...>');
    exit(1);
  }

  String action = effectiveArgs[argOffset];
  final client = FlutterSkillClient(uri);

  String? param1;
  String? param2;
  if (effectiveArgs.length > argOffset + 1) param1 = effectiveArgs[argOffset + 1];
  if (effectiveArgs.length > argOffset + 2) param2 = effectiveArgs[argOffset + 2];

  try {
    await client.connect();

    switch (action) {
      case 'tap':
        if (param1 == null) throw ArgumentError('tap requires a key or text');
        await client.tap(key: param1);
        print('Tapped "$param1"');
        break;

      case 'enter_text':
        if (param1 == null || param2 == null)
          throw ArgumentError('enter_text requires key and text');
        await client.enterText(param1, param2);
        print('Entered text "$param2" into "$param1"');
        break;

      case 'scroll_to':
        if (param1 == null)
          throw ArgumentError('scroll_to requires a key or text');
        await client.scrollTo(key: param1);
        print('Scrolled to "$param1"');
        break;

      case 'scroll':
        if (param1 == null)
          throw ArgumentError('scroll requires a key or text to scroll to');
        await client.scrollTo(key: param1);
        print('Scrolled to "$param1"');
        break;

      case 'screenshot':
        final image = await client.takeScreenshot();
        if (image != null) {
          // Save to file if path given, otherwise print base64 length
          if (param1 != null) {
            final bytes = base64Decode(image);
            await File(param1).writeAsBytes(bytes);
            print('Screenshot saved to $param1 (${bytes.length} bytes)');
          } else {
            print('Screenshot captured (${image.length} base64 chars)');
          }
        } else {
          print('Screenshot failed');
          exit(1);
        }
        break;

      case 'get_text':
        if (param1 == null) throw ArgumentError('get_text requires a key');
        final text = await client.getTextValue(param1);
        print(text ?? '(null)');
        break;

      case 'find_element':
        if (param1 == null)
          throw ArgumentError('find_element requires a key or text');
        final found = await client.waitForElement(key: param1, timeout: 2000);
        print(found ? 'Found "$param1"' : 'Not found "$param1"');
        break;

      case 'wait_for_element':
        if (param1 == null)
          throw ArgumentError('wait_for_element requires a key or text');
        final timeout = param2 != null ? int.tryParse(param2) ?? 5000 : 5000;
        final appeared =
            await client.waitForElement(key: param1, timeout: timeout);
        print(appeared ? 'Found "$param1"' : 'Timeout waiting for "$param1"');
        if (!appeared) exit(1);
        break;

      case 'go_back':
        await client.goBack();
        print('Navigated back');
        break;

      case 'swipe':
        final direction = param1 ?? 'up';
        final distance =
            param2 != null ? double.tryParse(param2) ?? 300 : 300.0;
        await client.swipe(direction: direction, distance: distance);
        print('Swiped $direction by $distance');
        break;

      case 'assert_visible':
        if (param1 == null)
          throw ArgumentError('assert_visible requires a key or text');
        final target = param1;
        final elements = await client.getInteractiveElements();
        if (_findTarget(elements, target)) {
          print('Assertion Passed: "$target" is visible.');
        } else {
          throw Exception('Assertion Failed: "$target" is NOT visible.');
        }
        break;

      case 'assert_gone':
        if (param1 == null)
          throw ArgumentError('assert_gone requires a key or text');
        final target = param1;
        final elements = await client.getInteractiveElements();
        if (!_findTarget(elements, target)) {
          print('Assertion Passed: "$target" is gone.');
        } else {
          throw Exception('Assertion Failed: "$target" is STILL visible.');
        }
        break;

      default:
        print('Unknown action: $action');
        exit(1);
    }
  } catch (e) {
    print('Error: $e');
    exit(1);
  } finally {
    await client.disconnect();
  }
}

// ---------------------------------------------------------------------------
// Server-forwarding helpers
// ---------------------------------------------------------------------------

/// Build a JSON-RPC method name + params from the act CLI args.
Map<String, dynamic> _buildRpcCall(List<String> actArgs) {
  if (actArgs.isEmpty) return {'method': 'ping', 'params': {}};

  final action = actArgs[0];
  final param1 = actArgs.length > 1 ? actArgs[1] : null;
  final param2 = actArgs.length > 2 ? actArgs[2] : null;

  switch (action) {
    case 'tap':
      return {
        'method': 'tap',
        'params': {'key': param1}
      };
    case 'enter_text':
      return {
        'method': 'enter_text',
        'params': {'key': param1, 'text': param2 ?? ''}
      };
    case 'scroll':
      // param1 = widget key/text to scroll to (matches direct VM path semantics)
      return {
        'method': 'scroll_to',
        'params': {'key': param1}
      };
    case 'scroll_to':
      return {
        'method': 'scroll_to',
        'params': {'key': param1, 'direction': param2 ?? 'down'}
      };
    case 'screenshot':
      return {
        'method': 'screenshot',
        'params': param1 != null ? {'path': param1} : <String, dynamic>{}
      };
    case 'swipe':
      return {
        'method': 'swipe',
        'params': {
          'direction': param1 ?? 'up',
          'distance': double.tryParse(param2 ?? '') ?? 300,
        }
      };
    case 'go_back':
      return {'method': 'go_back', 'params': {}};
    default:
      return {'method': action, 'params': {}};
  }
}

Future<void> _actViaServers(
    List<String> serverIds, List<String> actArgs, OutputFormat format) async {
  final rpc = _buildRpcCall(actArgs);
  final method = rpc['method'] as String;
  final params = rpc['params'] as Map<String, dynamic>;
  final action = actArgs.isNotEmpty ? actArgs[0] : method;

  final results =
      await callServersParallel(serverIds, method, params, actionLabel: action);

  // Handle screenshot save when --server is used (specific to this action).
  if (method == 'screenshot' && actArgs.length > 1) {
    final path = actArgs[1];
    for (final r in results) {
      if (r.success) {
        final image = r.data?['image'] as String?;
        if (image != null) {
          final bytes = base64Decode(image);
          await File(path).writeAsBytes(bytes);
        }
      }
    }
  }

  if (format == OutputFormat.json) {
    print(jsonEncode(results.map((r) => r.toJson()).toList()));
    return;
  }

  for (final r in results) {
    if (r.success) {
      print('[${r.serverId}] ${r.action} completed (${r.durationMs}ms)');
    } else {
      print('[${r.serverId}] Error: ${r.error}');
    }
  }

  // Exit with error code if any server failed.
  if (results.any((r) => !r.success)) exit(1);
}

// ---------------------------------------------------------------------------
// Existing helper (unchanged)
// ---------------------------------------------------------------------------

bool _findTarget(List<dynamic> elements, String target) {
  for (final e in elements) {
    if (e is! Map) continue;
    final key = e['key']?.toString();
    final text = e['text']?.toString();
    if (key == target || (text != null && text.contains(target))) {
      return true;
    }
    if (e.containsKey('children')) {
      if (_findTarget((e['children'] as List).cast<dynamic>(), target)) {
        return true;
      }
    }
  }
  return false;
}
