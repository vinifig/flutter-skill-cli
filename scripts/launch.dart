import 'dart:convert';
import 'dart:io';

// File to store the last connected URI
final _uriFile = File('.flutter_skill_uri');

void main(List<String> args) async {
  // Usage: dart run scripts/launch.dart [project_path]
  final projectPath = args.isNotEmpty ? args[0] : '.';

  print('Running auto-setup...');
  // We need to find setup.dart. Platform.script is launch.dart.
  final scriptDir = File(Platform.script.toFilePath()).parent.path;
  final setupScript = '$scriptDir/setup.dart';

  print('Running setup script: $setupScript');
  final setupRes = await Process.run('dart', ['run', setupScript, projectPath]);
  if (setupRes.exitCode != 0) {
    print('Setup failed: ${setupRes.stderr}');
    print('Proceeding with launch anyway...');
  } else {
    print(setupRes.stdout);
  }

  print('Launching Flutter app in: $projectPath');

  final process = await Process.start(
    'flutter',
    ['run'],
    workingDirectory: projectPath,
    mode: ProcessStartMode.normal, // Detached but we want to read stdout?
    // If we use detached, we might lose stdout depending on OS.
    // normal mode keeps it attached to THIS script.
    // If we want the app to keep running after this script exits,
    // we have a problem: we need to parse the URI first, THEN maybe exit?
    // But if we exit, `flutter run` typically dies unless detached.
    // But if detached, we can't easily read stdout without redirects.

    // For the "Agent" use case:
    // The Agent runs `launch.dart`. The agent waits.
    // If 'launch.dart' connects and then exits, the app dies.
    // So 'launch.dart' must stay alive as long as the app is running.
    // The Agent will likely put this in background or open a new terminal.

    // Actually, for CLI mode, the user usually runs `flutter run` in a separate tab.
    // PROPOSAL: `launch.dart` will run and BLOCK. The Agent should run it in background.
    // OR: `launch.dart` spawns a fully detached process that writes to a known log file?
    // Simpler: `launch.dart` runs and blocks. The Agent is smart enough to run it as a background process if needed,
    // OR the Agent just uses it to start, waits for URI, and then keeps it running.

    // Let's implement it as a blocking process that prints the URI and stays alive.
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

  // Forward stdin to flutter run (so we can hit 'R', 'q', etc)
  // stdin.listen((data) => process.stdin.add(data));
  // Requires typical stdin management
  if (stdin.hasTerminal) {
    stdin.listen((data) => process.stdin.add(data));
  }

  final exitCode = await process.exitCode;
  print('Flutter app exited with code $exitCode');
  exit(exitCode);
}

void _checkForUri(String line) {
  // Looking for: "The Flutter DevTools ... available at: http://... ?uri=ws://..."
  // Or just "ws://..."

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
