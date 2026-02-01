import 'dart:io';
import '../flutter_skill_client.dart';

Future<void> runAct(List<String> args) async {
  String uri;

  // Logic from bin/act.dart to separate URI from args
  String resolveUriResult;
  int argOffset;

  if (args.isNotEmpty &&
      (args[0].startsWith('ws://') || args[0].startsWith('http://'))) {
    resolveUriResult = args[0];
    argOffset = 1;
  } else {
    // Try file (we assume we are running from project root where .flutter_skill_uri might exist)
    // NOTE: If global activated, we might not be in the right dir?
    // Users should run this in their project root.
    final file = File('.flutter_skill_uri');
    if (await file.exists()) {
      resolveUriResult = (await file.readAsString()).trim();
    } else {
      print('Usage: flutter_skill act [vm-uri] <action> <params...>');
      exit(1);
    }
    argOffset = 0;
  }

  if (args.length <= argOffset) {
    print('Missing action argument');
    exit(1);
  }

  uri = resolveUriResult;
  String action = args[argOffset];
  final client = FlutterSkillClient(uri);

  String? param1;
  String? param2;
  if (args.length > argOffset + 1) param1 = args[argOffset + 1];
  if (args.length > argOffset + 2) param2 = args[argOffset + 2];

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
