import 'dart:io';
import 'package:flutter_skill/src/cli/launch.dart';
import 'package:flutter_skill/src/cli/inspect.dart';
import 'package:flutter_skill/src/cli/act.dart';
import 'package:flutter_skill/src/cli/server.dart';
import 'package:flutter_skill/src/cli/report_error.dart';
import 'package:flutter_skill/src/cli/setup_priority.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: flutter_skill <command> [arguments]');
    print('Commands:');
    print('  launch       - Launch and auto-connect to a Flutter app');
    print('  inspect      - Inspect interactive elements');
    print('  act          - Perform actions (tap, enter_text, etc)');
    print('  server       - Run MCP server');
    print('  setup        - Install tool priority rules for Claude Code');
    print('  report-error - Report a bug to GitHub Issues');

    // Show setup reminder if not installed
    showSetupReminder();
    exit(1);
  }

  final command = args[0];
  final commandArgs = args.sublist(1);

  switch (command) {
    case 'launch':
      await runLaunch(commandArgs);
      // Show setup reminder after launch (only if not installed)
      showSetupReminder();
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
    case 'setup':
      await runSetupPriority(commandArgs);
      break;
    case 'report-error':
      await runReportError(commandArgs);
      break;
    default:
      print('Unknown command: $command');
      exit(1);
  }
}
