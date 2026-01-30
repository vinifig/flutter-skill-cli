import 'dart:convert';
import 'dart:io';
import 'setup.dart'; // Import setup logic

// File to store the last connected URI
final _uriFile = File('.flutter_skill_uri');

Future<void> runLaunch(List<String> args) async {
  // Usage: flutter_skill launch [project_path]
  final projectPath = args.isNotEmpty ? args[0] : '.';

  print('Running auto-setup...');
  try {
    // Call the setup logic directly
    await runSetup(projectPath);
  } catch (e) {
    print('Setup failed: $e');
    print('Proceeding with launch anyway...');
  }

  print('Launching Flutter app in: $projectPath');

  final process = await Process.start(
    'flutter',
    ['run'],
    workingDirectory: projectPath,
    mode: ProcessStartMode.normal,
  );

  print(
      'Flutter process started (PID: ${process.pid}). Waiting for connection URI...');

  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    print('[Flutter]: $line');
    _checkForUri(line);
  });

  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    print('[Flutter Error]: $line');
  });

  // Forward stdin to flutter run
  if (stdin.hasTerminal) {
    stdin.listen((data) => process.stdin.add(data));
  }

  final exitCode = await process.exitCode;
  print('Flutter app exited with code $exitCode');
  exit(exitCode);
}

void _checkForUri(String line) {
  if (line.contains('ws://')) {
    final uriRegex = RegExp(r'ws://[a-zA-Z0-9.:/-]+');
    final match = uriRegex.firstMatch(line);
    if (match != null) {
      final uri = match.group(0)!;
      print('\nCode-Skill: Found VM Service URI: $uri');
      try {
        _uriFile.writeAsStringSync(uri);
        print(
            'Code-Skill: URI saved to .flutter_skill_uri. You can now run scripts without arguments.');
      } catch (e) {
        print('Code-Skill: Failed to save URI: $e');
      }
    }
  }
}
