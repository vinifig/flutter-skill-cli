import 'dart:io';
import 'lib/flutter_skill_client.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run scripts/reload.dart <vm-uri>');
    exit(1);
  }

  final uri = args[0];
  final client = FlutterSkillClient(uri);

  try {
    await client.connect();
    print('Triggering Hot Reload...');
    await client.hotReload();
    print('Hot Reload requested.');
  } catch (e) {
    print('Error: $e');
    exit(1);
  } finally {
    await client.disconnect();
  }
}
