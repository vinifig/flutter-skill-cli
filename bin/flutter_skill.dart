import 'dart:io';
import 'package:flutter_skill/src/cli/launch.dart';
import 'package:flutter_skill/src/cli/inspect.dart';
import 'package:flutter_skill/src/cli/act.dart';
import 'package:flutter_skill/src/cli/server.dart';
import 'package:flutter_skill/src/cli/server_cmd.dart';
import 'package:flutter_skill/src/cli/connect.dart';
import 'package:flutter_skill/src/cli/report_error.dart';
import 'package:flutter_skill/src/cli/setup_priority.dart';
import 'package:flutter_skill/src/cli/doctor.dart';
import 'package:flutter_skill/src/cli/init.dart';
import 'package:flutter_skill/src/cli/demo.dart';
import 'package:flutter_skill/src/cli/serve.dart';
import 'package:flutter_skill/src/cli/test_runner.dart';
import 'package:flutter_skill/src/cli/explore.dart';
import 'package:flutter_skill/src/cli/monkey.dart';
import 'package:flutter_skill/src/cli/plan.dart';
import 'package:flutter_skill/src/cli/security.dart';
import 'package:flutter_skill/src/cli/diff.dart';
import 'package:flutter_skill/src/cli/quickstart.dart';
import 'package:flutter_skill/src/cli/client.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('flutter-skill v$currentVersion - AI Agent Bridge for Flutter Apps');
    print('');
    print('Commands:');
    print('  init         Auto-setup any project (Flutter/iOS/Android/RN/Web)');
    print('  quickstart   Guided demo — see flutter-skill in action in 30s');
    print('  demo         Launch a built-in demo app — zero setup needed');
    print('  launch       Launch and auto-connect to an app');
    print('  connect      Attach to a running Flutter app and name it');
    print('  server       Start MCP server / manage named server instances');
    print('  servers      List all running named server instances');
    print('  inspect      Inspect interactive elements');
    print('  act          Perform actions (tap, enter_text, scroll)');
    print('  screenshot   Take a screenshot of the running app');
    print('  serve <url>  Zero-config WebMCP server — any site → AI tools');
    print('');
    print('Client commands (connect to running serve):');
    print('  nav <url>      Navigate to URL');
    print('  snap           Accessibility tree snapshot');
    print('  screenshot     Take screenshot');
    print('  tap <text>     Tap element by text, ref, or coordinates');
    print('  type <text>    Type text via keyboard');
    print('  key <key>      Press keyboard key');
    print('  eval <js>      Evaluate JavaScript');
    print('  title          Get page title');
    print('  text           Get visible text');
    print('  hover <text>   Hover over element');
    print('  upload <sel> <file>  Upload file');
    print('  tools          List available tools');
    print('  call <tool> [json]   Call any tool directly');
    print('  explore <url> AI Test Agent — auto-explore and test any web app');
    print('  monkey <url>  Monkey testing — random fuzz testing for web apps');
    print('  plan <url>    AI Test Plan Generator — auto-generate test cases');
    print(
        '  security <url> Security Scanner — XSS, CSRF, headers, sensitive data');
    print('  diff <url>    Diff testing — compare app state against baseline');
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
    case 'connect':
      await runConnect(commandArgs);
      break;
    case 'servers':
      // Shorthand for `server list`
      await runServerCmd(['list', ...commandArgs]);
      break;
    case 'server':
      // Route server subcommands (list, stop, status) to server_cmd.
      // Plain `server` (no subcommand) or `server` with MCP flags → MCP server.
      if (commandArgs.isNotEmpty &&
          const {'list', 'stop', 'status'}.contains(commandArgs[0])) {
        await runServerCmd(commandArgs);
      } else {
        await runServer(commandArgs);
      }
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
    case 'serve':
      await runServe(commandArgs);
      break;
    case 'explore':
      await runExplore(commandArgs);
      break;
    case 'test':
      if (commandArgs.isEmpty) {
        print('Usage: flutter-skill test <url> [options]');
        print('');
        print('Examples:');
        print('  flutter-skill test https://example.com');
        print(
            '  flutter-skill test --url=https://example.com --platforms=web,electron,android');
        print('');
        print('Options:');
        print('  --url=<url>             URL to test');
        print(
            '  --platforms=<list>      Platforms: web,electron,android,ios (default: web)');
        print('  --cdp-port=<port>       CDP port (default: 9222)');
        print('  --no-headless           Show browser window');
        print('  --report=<path>         Save JSON report to file');
        exit(1);
      }
      // Check if --platforms flag is used → parallel test runner
      final hasMultiPlatform =
          commandArgs.any((a) => a.startsWith('--platforms='));
      if (hasMultiPlatform) {
        await runTestRunner(commandArgs);
      } else {
        // Single-platform: convenience wrapper → server --url=<url>
        final testUrl = commandArgs.firstWhere((a) => !a.startsWith('--'),
            orElse: () => commandArgs
                .firstWhere((a) => a.startsWith('--url='), orElse: () => '')
                .replaceFirst('--url=', ''));
        if (testUrl.isEmpty) {
          print('Error: URL is required');
          exit(1);
        }
        final serverArgs = ['--url=$testUrl'];
        serverArgs.addAll(
            commandArgs.where((a) => a != testUrl && !a.startsWith('--url=')));
        await runServer(serverArgs);
      }
      break;
    case 'monkey':
      await runMonkey(commandArgs);
      break;
    case 'quickstart':
      await runQuickstart(commandArgs);
      break;
    case 'diff':
      await runDiff(commandArgs);
      break;
    case 'plan':
      await runPlan(commandArgs);
      break;
    case 'security':
      await runSecurity(commandArgs);
      break;
    // Client commands — connect to running serve instance
    case 'nav':
    case 'navigate':
    case 'go':
    case 'snap':
    case 'snapshot':
    case 'screenshot':
    case 'ss':
    case 'tap':
    case 'type':
    case 'key':
    case 'press':
    case 'eval':
    case 'js':
    case 'title':
    case 'text':
    case 'hover':
    case 'upload':
    case 'tools':
    case 'call':
    case 'wait':
      await runClient(command, commandArgs);
      break;
    default:
      print('Unknown command: $command');
      exit(1);
  }
}
