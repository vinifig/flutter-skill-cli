import 'dart:convert';
import 'dart:io';
import 'dart:async';

void main() async {
  print('=== STARTING SANDBOX VERIFICATION ===');

  // 1. Setup Environment
  final cwd = Directory.current.path;
  final mockFlutterPath = '$cwd/tests/bin';
  // Add mock flutter to PATH
  final env = Map<String, String>.from(Platform.environment);
  env['PATH'] = '$mockFlutterPath:${env['PATH']}';

  print('Environment PATH prepended with: $mockFlutterPath');

  // 1.5 Setup Test Dummy
  final dummyDir = Directory('test_dummy');
  if (!dummyDir.existsSync()) {
    print('Creating test_dummy project...');
    dummyDir.createSync();
    File('test_dummy/pubspec.yaml').writeAsStringSync('''
name: test_dummy
description: A new Flutter project.
publish_to: 'none'
version: 1.0.0+1
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.2
  flutter_skill: any
dev_dependencies:
  flutter_test:
    sdk: flutter
flutter:
  uses-material-design: true
''');
    Directory('test_dummy/lib').createSync(recursive: true);
    File('test_dummy/lib/main.dart').writeAsStringSync('''
import 'package:flutter/material.dart';
void main() { runApp(const MyApp()); }
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: Scaffold(body: Text('Hello')));
  }
}
''');
  }

  // 2. Test "launch.dart" (CLI Automation)
  print('\n[TEST 1] Testing launch.dart ...');
  final launchProcess = await Process.start(
    'dart',
    ['run', 'scripts/launch.dart', 'test_dummy'],
    environment: env,
    mode: ProcessStartMode.normal,
  );

  // Pipe stdout/stderr to see what's happening
  launchProcess.stdout.transform(utf8.decoder).listen((data) {
    print('[LAUNCH STDOUT]: $data');
  });
  launchProcess.stderr.transform(utf8.decoder).listen((data) {
    print('[LAUNCH STDERR]: $data');
  });

  // We need to wait for .flutter_skill_uri to appear.
  final uriFile = File('.flutter_skill_uri');
  if (uriFile.existsSync()) uriFile.deleteSync();

  // Poll for file
  int attempts = 0;
  String? uri;
  while (attempts < 20) {
    await Future.delayed(Duration(milliseconds: 500));
    if (uriFile.existsSync()) {
      uri = uriFile.readAsStringSync();
      if (uri.startsWith('ws://')) break;
    }
    attempts++;
  }

  if (uri == null) {
    print('[FAIL] Test 1: launch.dart did not produce URI file.');
    launchProcess.kill();
    exit(1);
  }
  print('[PASS] Test 1: launch.dart produced URI: $uri');

  // 3. Test "inspect.dart" (CLI Interaction)
  print('\n[TEST 2] Testing inspect.dart against running mock...');
  final inspectProcess = await Process.start('dart', [
    'run',
    'scripts/inspect.dart',
  ]);
  final inspectStdout = StringBuffer();

  inspectProcess.stdout.transform(utf8.decoder).listen((data) {
    print('[INSPECT STDOUT]: $data');
    inspectStdout.write(data);
  });
  inspectProcess.stderr
      .transform(utf8.decoder)
      .listen((data) => print('[INSPECT STDERR]: $data'));

  final inspectExitCode = await inspectProcess.exitCode;

  if (inspectExitCode != 0) {
    print('[FAIL] inspect.dart failed');
    inspectProcess.kill();
    exit(1);
  }

  print('[PASS] Test 2: inspect.dart exited with $inspectExitCode');

  if (!inspectStdout.toString().contains('login_btn')) {
    print(
      '[FAIL] inspect.dart did not find "login_btn". Output:\n${inspectStdout.toString()}',
    );
    exit(1);
  }
  print('[PASS] Test 2: inspect.dart found elements.');

  // 4. Test "act.dart" (CLI Action)
  print('\n[TEST 3] Testing act.dart tap...');
  final actRes = await Process.run('dart', [
    'run',
    'scripts/act.dart',
    'tap',
    'login_btn',
  ]);
  if (actRes.exitCode != 0) {
    print('[FAIL] act.dart failed: ${actRes.stderr}');
    exit(1);
  }
  print('[PASS] Test 3: act.dart executed successfully.');

  // 5. Test "server.dart" (MCP Mode)
  print('\n[TEST 4] Testing server.dart (MCP Mode)...');
  // We spawn server.dart
  final serverProcess = await Process.start('dart', [
    'run',
    'scripts/server.dart',
  ]);

  // We send JSON-RPC commands
  final stdin = serverProcess.stdin;
  final stdoutStream = serverProcess.stdout
      .transform(SystemEncoding().decoder)
      .transform(const LineSplitter())
      .asBroadcastStream();

  // A. Connect
  final connectReq =
      '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "connect_app", "arguments": {"uri": "$uri"}}}';
  stdin.writeln(connectReq);

  // Listener for server responses
  final completerT4 = Completer<bool>();

  stdoutStream.listen((line) {
    print('[MCP Server Output]: $line');
    if (line.contains('"result"')) {
      if (line.contains('Connected to')) {
        print('[PASS] MCP Connect success');
        // B. Tap via MCP
        final tapReq =
            '{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "tap", "arguments": {"key": "login_btn"}}}';
        stdin.writeln(tapReq);
      } else if (line.contains('Tapped')) {
        print('[PASS] MCP Tap success');
        completerT4.complete(true);
      }
    }
  });

  try {
    await completerT4.future.timeout(Duration(seconds: 5));
  } catch (e) {
    print('[FAIL] Test 4: MCP Server timed out or failed.');
    serverProcess.kill();
    launchProcess.kill();
    exit(1);
  }

  // Cleanup
  serverProcess.kill();
  launchProcess.kill();

  print('\n=== ALL TESTS PASSED ===');
  exit(0);
}
