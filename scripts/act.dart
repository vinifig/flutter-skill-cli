import 'dart:io';
import 'lib/flutter_skill_client.dart';

void main(List<String> args) async {
  String uri;
  try {
    uri = await FlutterSkillClient.resolveUri(args);
  } catch (e) {
    print(e);
    exit(1);
  }

  // Action is args[1] usually, but if we auto-resolved uri, wait.
  // resolveUri takes `args`. If `args` has URI, it returns it.
  // But for `act.dart`, we pass `uri action params...`.
  // If `uri` is omitted, `args[0]` might be `action`.

  // We need to detect if args[0] is URI or Action.
  // resolveUri logic: "if arg starts with ws://".

  // If args[0] is "tap", resolveUri will NOT pick it up and fallback to file.
  // BUT we need to shift args if URI was NOT present in args.

  String action;

  if (args.isNotEmpty &&
      (args[0].startsWith('ws://') || args[0].startsWith('http://'))) {
    // URI provided
    action = args[1];
    // params are args[2...] which is index 0 of remaining?
    // act.dart expects `target` at args[2].
    // Let's rely on indices.
    // This is getting complex to support both.
    // Let's standardise the behavior logic inside this script.
  }

  // Simpler approach:
  // If we found URI in args[0], then action is args[1].
  // If we found URI in file, then action is args[0].

  String resolveUriResult;
  int argOffset;

  if (args.isNotEmpty &&
      (args[0].startsWith('ws://') || args[0].startsWith('http://'))) {
    resolveUriResult = args[0];
    argOffset = 1;
  } else {
    // Try file
    final file = File('.flutter_skill_uri');
    if (await file.exists()) {
      resolveUriResult = (await file.readAsString()).trim();
    } else {
      print('Usage: dart run scripts/act.dart [vm-uri] <action> <params...>');
      exit(1);
    }
    argOffset = 0;
  }

  if (args.length <= argOffset) {
    print('Missing action argument');
    exit(1);
  }

  uri = resolveUriResult;
  action = args[argOffset];
  final client = FlutterSkillClient(uri);

  // Now we need to handle params.
  // The switch cases use `args[2]` etc assuming URI is present.
  // We should map them relative to `action`.
  // Let `param1` be `args[argOffset+1]`

  String? param1;
  String? param2;
  if (args.length > argOffset + 1) param1 = args[argOffset + 1];
  if (args.length > argOffset + 2) param2 = args[argOffset + 2];

  // We need to rewrite the main logic to use param variables or a new list.
  // Let's rewrite the main body.

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
