import 'dart:io';
import 'package:flutter_skill/src/cli/launch.dart';
import 'package:flutter_skill/src/cli/inspect.dart';
import 'package:flutter_skill/src/cli/act.dart';
import 'package:flutter_skill/src/cli/server.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: flutter_skill <command> [arguments]');
    print('Commands:');
    print('  launch  - Launch and auto-connect to a Flutter app');
    print('  inspect - Inspect interactive elements');
    print('  act     - Perform actions (tap, enter_text, etc)');
    print('  server  - Run MCP server');
    exit(1);
  }

  final command = args[0];
  final commandArgs = args.sublist(1);

  switch (command) {
    case 'launch':
      await runLaunch(commandArgs);
      break;
    case 'inspect':
      await runInspect(commandArgs);
      break;
    case 'act':
      await runAct(commandArgs);
      break;
    case 'server':
      await runServer(commandArgs);
      break;
    default:
      print('Unknown command: $command');
      exit(1);
  }
}
