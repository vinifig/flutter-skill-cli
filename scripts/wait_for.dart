import 'dart:io';
import 'lib/flutter_skill_client.dart';

void main(List<String> args) async {
  if (args.length < 2) {
    print(
        'Usage: dart run scripts/wait_for.dart <vm-uri> <key_or_text> [timeout_seconds]');
    exit(1);
  }

  final uri = args[0];
  final target = args[1];
  final timeout = args.length > 2 ? int.tryParse(args[2]) ?? 10 : 10;

  final client = FlutterSkillClient(uri);

  try {
    await client.connect();
    print('Waiting for "$target" (timeout: ${timeout}s)...');

    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed.inSeconds < timeout) {
      final elements = await client.getInteractiveElements();
      if (_findTarget(elements, target)) {
        print('Found "$target"!');
        exit(0);
      }
      await Future.delayed(Duration(milliseconds: 500));
    }

    print('Timeout waiting for "$target"');
    exit(1);
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
