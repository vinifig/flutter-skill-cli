import 'dart:io';
import 'lib/flutter_skill_client.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run scripts/log.dart <vm-uri>');
    exit(1);
  }

  final uri = args[0];
  final client = FlutterSkillClient(uri);

  try {
    await client.connect();
    final logs = await client.getLogs();

    if (logs.isEmpty) {
      print('(No logs found)');
    } else {
      for (final log in logs) {
        print(log);
      }
    }
  } catch (e) {
    print('Error: $e');
    exit(1);
  } finally {
    await client.disconnect();
  }
}
