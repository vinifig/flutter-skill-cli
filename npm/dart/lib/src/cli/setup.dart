import 'dart:io';

Future<void> runSetup(String projectPath) async {
  final pubspecFile = File('$projectPath/pubspec.yaml');
  final mainFile = File('$projectPath/lib/main.dart');

  if (!pubspecFile.existsSync()) {
    print('Error: pubspec.yaml not found at $projectPath');
    exit(1);
  }

  if (!mainFile.existsSync()) {
    print('Error: lib/main.dart not found at $projectPath');
    exit(1);
  }

  print('Checking dependencies in ${pubspecFile.path}...');
  final pubspecContent = pubspecFile.readAsStringSync();

  if (!pubspecContent.contains('flutter_skill:')) {
    print('Adding flutter_skill dependency...');
    final result = await Process.run(
      'flutter',
      ['pub', 'add', 'flutter_skill'],
      workingDirectory: projectPath,
    );
    if (result.exitCode != 0) {
      print('Failed to add dependency: ${result.stderr}');
      exit(1);
    }
    print('Dependency added.');
  } else {
    print('Dependency flutter_skill already exists.');
  }

  print('Checking instrumentation in ${mainFile.path}...');
  String mainContent = mainFile.readAsStringSync();

  bool changed = false;

  // 1. Check Import
  if (!mainContent.contains('package:flutter_skill/flutter_skill.dart')) {
    mainContent =
        "import 'package:flutter_skill/flutter_skill.dart';\nimport 'package:flutter/foundation.dart'; // For kDebugMode\n" +
            mainContent;
    changed = true;
    print('Added imports.');
  }

  // 2. Check Initialization
  if (!mainContent.contains('FlutterSkillBinding.ensureInitialized()')) {
    final mainRegex = RegExp(r'void\s+main\s*\(\s*\)\s*\{');
    final match = mainRegex.firstMatch(mainContent);

    if (match != null) {
      final end = match.end;
      const injection =
          '\n  if (kDebugMode) {\n    FlutterSkillBinding.ensureInitialized();\n  }\n';
      mainContent = mainContent.replaceRange(end, end, injection);
      changed = true;
      print('Added FlutterSkillBinding initialization.');
    } else {
      print(
          'Warning: Could not find "void main() {" to inject code. Manual setup required.');
    }
  }

  if (changed) {
    mainFile.writeAsStringSync(mainContent);
    print('Updated lib/main.dart.');
  } else {
    print('No changes needed for lib/main.dart.');
  }

  print('Setup complete.');
}
