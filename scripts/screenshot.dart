import 'dart:convert';
import 'dart:io';
import 'lib/flutter_skill_client.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run scripts/screenshot.dart <vm-uri> [output_path]');
    exit(1);
  }

  final uri = args[0];
  final outputPath = args.length > 1 ? args[1] : 'screenshot.png';

  final client = FlutterSkillClient(uri);

  try {
    await client.connect();
    final base64Image = await client.takeScreenshot();

    if (base64Image.isEmpty) {
      print('Failed to take screenshot (empty result)');
      exit(1);
    }

    final bytes = base64Decode(base64Image);
    await File(outputPath).writeAsBytes(bytes);
    print('Screenshot saved to $outputPath');
  } catch (e) {
    print('Error: $e');
    exit(1);
  } finally {
    await client.disconnect();
  }
}
