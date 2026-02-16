import 'dart:io';
import 'package:flutter_skill/src/cli/launch.dart';
import 'package:flutter_skill/src/cli/inspect.dart';
import 'package:flutter_skill/src/cli/act.dart';
import 'package:flutter_skill/src/cli/server.dart';
import 'package:flutter_skill/src/cli/report_error.dart';
import 'package:flutter_skill/src/cli/setup_priority.dart';
import 'package:flutter_skill/src/cli/doctor.dart';
import 'package:flutter_skill/src/cli/init.dart';
import 'package:flutter_skill/src/cli/demo.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('flutter-skill v$currentVersion - AI Agent Bridge for Flutter Apps');
    print('');
    print('Commands:');
    print('  init         Auto-setup any project (Flutter/iOS/Android/RN/Web)');
    print('  demo         Launch a built-in demo app — zero setup needed');
    print('  launch       Launch and auto-connect to an app');
    print('  server       Start MCP server (used by IDEs)');
    print('  inspect      Inspect interactive elements');
    print('  act          Perform actions (tap, enter_text, scroll)');
    print('  screenshot   Take a screenshot of the running app');
    print('  test <url>   Zero-config web testing — launch Chrome + CDP');
    print('  doctor       Check installation and environment health');
    print('  setup        Install tool priority rules for Claude Code');
    print('  report-error Report a bug to GitHub Issues');
    print('  --version    Show version');
    print('');
    print('Quick Start:');
    print(
        '  flutter-skill demo                Try it now — no project needed!');
    print('  flutter-skill init ./my_app       Auto-setup any project');
    print('  flutter-skill launch ./my_app     Launch and connect to your app');
    print('');
    print('What can AI agents do with Flutter Skill?');
    print('  - Launch your Flutter app and auto-connect');
    print('  - Inspect UI: find buttons, text fields, lists');
    print('  - Tap, swipe, scroll, and enter text');
    print('  - Take screenshots to verify visual changes');
    print('  - Read app logs and debug issues');
    print('  - Hot reload after code changes');
    print('');
    print('Example: Ask your AI agent:');
    print('  "Launch my Flutter app and tap the login button"');
    print('  "Take a screenshot and check if the list is showing"');
    print('  "Enter \'hello@test.com\' in the email field and submit"');
    print('');
    print('Docs: https://pub.dev/packages/flutter_skill');

    // Show setup reminder if not installed
    showSetupReminder();
    exit(1);
  }

  final command = args[0];
  final commandArgs = args.sublist(1);

  switch (command) {
    case '--version':
    case '-v':
      print(currentVersion);
      break;
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
    case 'doctor':
      await runDoctor(commandArgs);
      break;
    case 'init':
      await runInit(commandArgs);
      break;
    case 'demo':
      await runDemo(commandArgs);
      break;
    case 'report-error':
      await runReportError(commandArgs);
      break;
    case 'test':
      // Convenience wrapper: `flutter-skill test <url>` → `server --url=<url>`
      if (commandArgs.isEmpty) {
        print('Usage: flutter-skill test <url>');
        print('');
        print('Example: flutter-skill test https://example.com');
        print('');
        print('Launches Chrome, navigates to the URL, and starts the MCP server');
        print('with CDP auto-connected. No setup needed.');
        exit(1);
      }
      final testUrl = commandArgs[0];
      final serverArgs = ['--url=$testUrl'];
      // Pass through any additional flags (e.g. --cdp-port=9333)
      serverArgs.addAll(commandArgs.sublist(1));
      await runServer(serverArgs);
      break;
    default:
      print('Unknown command: $command');
      exit(1);
  }
}
