import 'dart:async';
import 'dart:io';

import '../drivers/flutter_driver.dart';
import '../skill_server.dart';

/// CLI command: `flutter_skill connect --id=<name> [--port=<port>|--uri=<uri>]`
///
/// Attaches to a running Flutter app (identified by VM Service port or URI),
/// wraps it in a [SkillServer], registers the server in the registry, and
/// keeps running until Ctrl+C.
Future<void> runConnect(List<String> args) async {
  String? id;
  int? port;
  String? uri;
  String projectPath = '.';
  String deviceId = '';

  for (final arg in args) {
    if (arg.startsWith('--id=')) {
      id = arg.substring('--id='.length);
    } else if (arg.startsWith('--port=')) {
      port = int.tryParse(arg.substring('--port='.length));
    } else if (arg.startsWith('--uri=')) {
      uri = arg.substring('--uri='.length);
    } else if (arg.startsWith('--project=')) {
      projectPath = arg.substring('--project='.length);
    } else if (arg.startsWith('--device=')) {
      deviceId = arg.substring('--device='.length);
    }
  }

  if (id == null) {
    print('Usage: flutter_skill connect --id=<name> [--port=<port>|--uri=<uri>]');
    print('');
    print('Options:');
    print('  --id=<name>    Server name (required)');
    print('  --port=<port>  VM Service port (e.g. 50000)');
    print('  --uri=<uri>    VM Service URI (e.g. ws://127.0.0.1:50000/ws)');
    print('  --project=<p>  Project path (for registry metadata)');
    print('  --device=<d>   Device ID (for registry metadata)');
    exit(1);
  }

  // Build the WebSocket URI.
  if (uri == null) {
    if (port != null) {
      uri = 'ws://127.0.0.1:$port/ws';
    } else {
      // Fall back to auto-discovery.
      try {
        uri = await FlutterSkillClient.resolveUri([]);
      } catch (e) {
        print('Error: $e');
        exit(1);
      }
    }
  }

  // Normalise http:// → ws://
  if (uri.startsWith('http://')) {
    uri = uri.replaceFirst('http://', 'ws://');
    if (!uri.endsWith('/ws')) uri = '$uri/ws';
  }

  // Normalise https:// → wss://
  if (uri.startsWith('https://')) {
    uri = uri.replaceFirst('https://', 'wss://');
    if (!uri.endsWith('/ws')) uri = '$uri/ws';
  }

  print('Connecting to Flutter app at $uri...');
  final driver = FlutterSkillClient(uri);
  try {
    await driver.connect();
  } catch (e) {
    print('Failed to connect: $e');
    exit(1);
  }
  print('Connected.');

  final server = SkillServer(
    id: id,
    driver: driver,
    projectPath: projectPath,
    deviceId: deviceId,
  );

  await server.start();
  print('Skill server "$id" listening on port ${server.port}');
  print('Press Ctrl+C to stop.');

  // Keep running until the process is interrupted.
  final shutdown = Completer<void>();

  ProcessSignal.sigint.watch().first.then((_) async {
    print('\nShutting down server "$id"...');
    await server.stop();
    await driver.disconnect();
    shutdown.complete();
  });

  // Also handle SIGTERM on Unix.
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().first.then((_) async {
      await server.stop();
      await driver.disconnect();
      if (!shutdown.isCompleted) shutdown.complete();
    });
  }

  await shutdown.future;
  exit(0);
}
