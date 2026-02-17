import 'dart:io';
import 'dart:convert';
import 'package:flutter_skill/src/cli/server.dart' show currentVersion;

/// Run the doctor command to check installation health
Future<void> runDoctor(List<String> args) async {
  print('Flutter Skill Doctor');
  print('=' * 50);
  print('');

  int okCount = 0;
  int warnCount = 0;
  int errorCount = 0;

  // 1. Flutter Skill version
  final version = await _getFlutterSkillVersion();
  if (version != null) {
    _printOk('Flutter Skill v$version');
    okCount++;
  } else {
    _printWarn('Flutter Skill version unknown');
    warnCount++;
  }

  // 2. Runtime type (native binary vs Dart)
  final runtime = _detectRuntime();
  if (runtime == 'native') {
    _printOk('Runtime: Native binary (fast startup)');
    okCount++;
  } else {
    _printInfo(
        'Runtime: Dart VM (slower startup, consider installing native binary)');
    okCount++;
  }

  // 3. Flutter SDK
  final flutterVersion = await _runCommand('flutter', ['--version']);
  if (flutterVersion != null) {
    final firstLine = flutterVersion.split('\n').first.trim();
    _printOk('Flutter SDK: $firstLine');
    okCount++;
  } else {
    _printError('Flutter SDK not found');
    print('         Install: https://flutter.dev/docs/get-started/install');
    errorCount++;
  }

  // 4. Dart SDK
  final dartVersion = await _runCommand('dart', ['--version']);
  if (dartVersion != null) {
    _printOk('Dart SDK: ${dartVersion.trim()}');
    okCount++;
  } else {
    _printError('Dart SDK not found');
    errorCount++;
  }

  // 5. Connected devices
  print('');
  print('Devices:');
  await _checkDevices();

  // 6. Native driver tools
  print('');
  print('Native Driver Tools:');
  if (Platform.isMacOS) {
    final hasXcrun = await _isCommandAvailable('xcrun');
    final hasOsascript = await _isCommandAvailable('osascript');
    if (hasXcrun) {
      _printOk('xcrun (iOS Simulator)');
      okCount++;
    } else {
      _printError('xcrun not found (install Xcode Command Line Tools)');
      errorCount++;
    }
    if (hasOsascript) {
      _printOk('osascript (macOS Accessibility API)');
      okCount++;
    } else {
      _printError('osascript not found');
      errorCount++;
    }
  }

  final hasAdb = await _isCommandAvailable('adb');
  if (hasAdb) {
    _printOk('adb (Android Emulator)');
    okCount++;
  } else {
    _printWarn(
        'adb not found (needed for Android Emulator native interaction)');
    print('         Install: Android SDK Platform Tools');
    warnCount++;
  }

  // 7. Tool priority rules
  print('');
  print('Configuration:');
  final homeDir =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (homeDir != null) {
    final rulesFile = File('$homeDir/.claude/prompts/flutter-tool-priority.md');
    if (rulesFile.existsSync()) {
      _printOk('Tool priority rules installed');
      okCount++;
    } else {
      _printWarn('Tool priority rules not installed');
      print('         Run: flutter_skill setup');
      warnCount++;
    }
  }

  // 8. IDE MCP configuration
  if (homeDir != null) {
    // Claude Code
    final claudeSettings = File('$homeDir/.claude/settings.json');
    if (claudeSettings.existsSync()) {
      try {
        final content = claudeSettings.readAsStringSync();
        if (content.contains('flutter-skill') ||
            content.contains('flutter_skill')) {
          _printOk('Claude Code MCP: configured');
          okCount++;
        } else {
          _printWarn('Claude Code MCP: not configured');
          print('         Add flutter-skill to mcpServers in settings');
          warnCount++;
        }
      } catch (_) {
        _printWarn('Claude Code MCP: could not read settings');
        warnCount++;
      }
    } else {
      _printInfo('Claude Code: not installed or not configured');
    }

    // Cursor
    final cursorConfig = File('$homeDir/.cursor/mcp.json');
    if (cursorConfig.existsSync()) {
      try {
        final content = cursorConfig.readAsStringSync();
        if (content.contains('flutter-skill') ||
            content.contains('flutter_skill')) {
          _printOk('Cursor MCP: configured');
          okCount++;
        } else {
          _printWarn('Cursor MCP: not configured');
          print(
              '         Add flutter-skill to mcpServers in ~/.cursor/mcp.json');
          warnCount++;
        }
      } catch (_) {
        _printWarn('Cursor MCP: could not read config');
        warnCount++;
      }
    }
  }

  // Check Chrome for CDP/serve mode
  print('');
  print('CDP / Serve Mode:');
  try {
    String chromePath;
    if (Platform.isMacOS) {
      chromePath =
          '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    } else if (Platform.isLinux) {
      chromePath = 'google-chrome';
    } else {
      chromePath = 'chrome.exe';
    }
    if (Platform.isMacOS && await File(chromePath).exists()) {
      final result = await Process.run(chromePath, ['--version']);
      _printOk('Chrome: ${(result.stdout as String).trim()}');
      okCount++;
    } else {
      final result = await Process.run('which', ['google-chrome']);
      if (result.exitCode == 0) {
        _printOk('Chrome found');
        okCount++;
      } else {
        _printWarn('Chrome not found — needed for serve/test commands');
        warnCount++;
      }
    }
  } catch (_) {
    _printInfo('Could not check Chrome');
  }

  // Check for common port conflicts
  try {
    final result = await Process.run('lsof', ['-i', ':9222', '-t']);
    if (result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty) {
      _printInfo('Port 9222 in use — CDP may need --cdp-port flag');
    } else {
      _printOk('Port 9222 available for CDP');
      okCount++;
    }
  } catch (_) {}

  // Check bridge port range
  try {
    final result = await Process.run('lsof', ['-i', ':18118', '-t']);
    if (result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty) {
      _printOk('Bridge port 18118 active (app may be running)');
      okCount++;
    } else {
      _printInfo('Bridge port 18118 free (no app detected)');
    }
  } catch (_) {}

  // Summary
  print('');
  print('=' * 50);
  if (errorCount == 0 && warnCount == 0) {
    print('All checks passed! ($okCount OK)');
  } else if (errorCount == 0) {
    print('$okCount OK, $warnCount warnings');
  } else {
    print('$okCount OK, $warnCount warnings, $errorCount errors');
  }
  print('');
}

void _printOk(String message) {
  print('  [OK] $message');
}

void _printWarn(String message) {
  print('  [!]  $message');
}

void _printError(String message) {
  print('  [X]  $message');
}

void _printInfo(String message) {
  print('  [i]  $message');
}

Future<String?> _getFlutterSkillVersion() async {
  return currentVersion;
}

String _detectRuntime() {
  // If running via dart, the executable path contains 'dart'
  final executable = Platform.resolvedExecutable;
  if (executable.contains('dart')) {
    return 'dart';
  }
  return 'native';
}

Future<String?> _runCommand(String command, List<String> args) async {
  try {
    final result = await Process.run(command, args);
    if (result.exitCode == 0) {
      final output = (result.stdout as String).trim();
      if (output.isNotEmpty) return output;
      // Some tools output to stderr (dart --version)
      final errOutput = (result.stderr as String).trim();
      if (errOutput.isNotEmpty) return errOutput;
    }
  } catch (_) {}
  return null;
}

Future<bool> _isCommandAvailable(String command) async {
  try {
    final result = await Process.run('which', [command]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<void> _checkDevices() async {
  // Check iOS Simulators
  if (Platform.isMacOS) {
    try {
      final result = await Process.run(
        'xcrun',
        ['simctl', 'list', 'devices', 'booted', '-j'],
      );
      if (result.exitCode == 0) {
        final json = jsonDecode(result.stdout as String);
        final devices = json['devices'] as Map<String, dynamic>? ?? {};
        int bootedCount = 0;
        for (final runtime in devices.values) {
          if (runtime is List) {
            for (final device in runtime) {
              if (device['state'] == 'Booted') {
                bootedCount++;
                _printOk(
                    'iOS Simulator: ${device['name']} (${device['udid']})');
              }
            }
          }
        }
        if (bootedCount == 0) {
          _printInfo('No booted iOS Simulators');
        }
      }
    } catch (_) {
      _printInfo('Could not check iOS Simulators');
    }
  }

  // Check Android Emulators
  try {
    final result = await Process.run('adb', ['devices', '-l']);
    if (result.exitCode == 0) {
      final lines = (result.stdout as String).split('\n');
      int deviceCount = 0;
      for (final line in lines.skip(1)) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty && trimmed.contains('device')) {
          deviceCount++;
          final parts = trimmed.split(RegExp(r'\s+'));
          final id = parts.first;
          final model =
              RegExp(r'model:(\S+)').firstMatch(trimmed)?.group(1) ?? '';
          _printOk('Android: $id ${model.isNotEmpty ? "($model)" : ""}');
        }
      }
      if (deviceCount == 0) {
        _printInfo('No connected Android devices/emulators');
      }
    }
  } catch (_) {
    _printInfo('Could not check Android devices');
  }
}
