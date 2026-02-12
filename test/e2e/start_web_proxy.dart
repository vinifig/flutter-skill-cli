/// Starts the WebBridgeProxy and keeps it running.
/// Usage: dart run test/e2e/start_web_proxy.dart
import 'dart:io';
import 'package:flutter_skill/src/bridge/web_bridge_proxy.dart';
import 'package:flutter_skill/src/bridge/bridge_protocol.dart';

Future<void> main() async {
  final proxy = WebBridgeProxy(cdpPort: 9222, bridgePort: bridgeDefaultPort);

  print('Starting WebBridgeProxy...');
  print('  CDP port: 9222');
  print('  Bridge port: $bridgeDefaultPort');

  try {
    await proxy.start();
    print('WebBridgeProxy started successfully!');
    print('  Health: http://127.0.0.1:$bridgeDefaultPort/.flutter-skill');
    print('  WS: ws://127.0.0.1:$bridgeDefaultPort/ws');
    print('Press Ctrl+C to stop.');

    // Keep running
    await ProcessSignal.sigint.watch().first;
    print('\nStopping...');
    await proxy.stop();
  } catch (e, st) {
    print('Error: $e');
    print(st);
    exit(1);
  }
}
