#!/usr/bin/env dart
/// One-command release script.
///
/// Usage:
///   dart scripts/release.dart 0.2.16 "Brief description of this release"
///
/// What it does:
///   1. Validates version format
///   2. Updates version in all files
///   3. Prepends CHANGELOG.md entry (you edit it)
///   4. Git commit + tag + push
///   5. Triggers GitHub Actions release workflow

import 'dart:io';

void main(List<String> args) async {
  if (args.isEmpty) {
    printUsage();
    exit(1);
  }

  final version = args[0];
  final description = args.length > 1 ? args.sublist(1).join(' ') : 'Release $version';

  // Validate version format
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
    print('❌ Invalid version format: $version');
    print('   Expected format: x.y.z (e.g., 0.2.16)');
    exit(1);
  }

  final projectRoot = Directory.current.path;

  print('🚀 Releasing v$version\n');

  // Step 1: Check for uncommitted changes
  print('📋 Checking git status...');
  final status = Process.runSync('git', ['status', '--porcelain']);
  if ((status.stdout as String).trim().isNotEmpty) {
    print('⚠️  You have uncommitted changes:');
    print(status.stdout);
    print('');
    if (!confirm('Continue anyway?')) {
      print('Aborted.');
      exit(0);
    }
  }

  // Step 2: Sync version to all files
  print('\n📦 Syncing version to all files...');
  syncVersion(projectRoot, version);

  // Step 3: Update CHANGELOG
  print('\n📝 Updating CHANGELOG.md...');
  updateChangelog(projectRoot, version, description);

  // Step 4: Show changes and confirm
  print('\n📋 Changes to be committed:');
  Process.runSync('git', ['add', '-A']);
  final diff = Process.runSync('git', ['diff', '--cached', '--stat']);
  print(diff.stdout);

  if (!confirm('Commit, tag, and push v$version?')) {
    print('Aborted. Changes are staged but not committed.');
    exit(0);
  }

  // Step 5: Commit
  print('\n💾 Committing...');
  final commitResult = Process.runSync('git', [
    'commit',
    '-m',
    'chore: Release v$version\n\n$description',
  ]);
  if (commitResult.exitCode != 0) {
    print('❌ Commit failed: ${commitResult.stderr}');
    exit(1);
  }

  // Step 6: Tag
  print('🏷️  Creating tag v$version...');
  final tagResult = Process.runSync('git', ['tag', 'v$version']);
  if (tagResult.exitCode != 0) {
    print('❌ Tag failed: ${tagResult.stderr}');
    exit(1);
  }

  // Step 7: Push
  print('📤 Pushing to origin...');
  final pushResult = Process.runSync('git', ['push', 'origin', 'main', '--tags']);
  if (pushResult.exitCode != 0) {
    print('❌ Push failed: ${pushResult.stderr}');
    exit(1);
  }

  print('\n✅ Released v$version successfully!');
  print('');
  print('🔗 GitHub Actions: https://github.com/ai-dashboad/flutter-skill/actions');
  print('');
  print('Publishing to:');
  print('  • pub.dev');
  print('  • npm');
  print('  • VSCode Marketplace');
  print('  • JetBrains Marketplace');
  print('  • Homebrew');
}

void printUsage() {
  print('''
Usage: dart scripts/release.dart <version> [description]

Examples:
  dart scripts/release.dart 0.2.16 "Bug fixes and performance improvements"
  dart scripts/release.dart 0.3.0 "Major feature release"

What it does:
  1. Updates version in pubspec.yaml, package.json, etc.
  2. Adds entry to CHANGELOG.md
  3. Commits, tags, and pushes
  4. Triggers GitHub Actions release workflow
''');
}

bool confirm(String message) {
  stdout.write('$message [y/N] ');
  final input = stdin.readLineSync()?.toLowerCase() ?? '';
  return input == 'y' || input == 'yes';
}

void syncVersion(String root, String version) {
  // pubspec.yaml
  updateFile('$root/pubspec.yaml',
    RegExp(r'^version:\s*.+$', multiLine: true),
    'version: $version');
  print('  ✓ pubspec.yaml');

  // npm/package.json
  updateFile('$root/npm/package.json',
    RegExp(r'"version":\s*"[^"]+"'),
    '"version": "$version"');
  print('  ✓ npm/package.json');

  // vscode-extension/package.json
  updateFile('$root/vscode-extension/package.json',
    RegExp(r'"version":\s*"[^"]+"'),
    '"version": "$version"');
  print('  ✓ vscode-extension/package.json');

  // intellij-plugin/build.gradle.kts
  updateFile('$root/intellij-plugin/build.gradle.kts',
    RegExp(r'version\s*=\s*"[^"]+"'),
    'version = "$version"');
  print('  ✓ intellij-plugin/build.gradle.kts');

  // intellij-plugin/plugin.xml
  updateFile('$root/intellij-plugin/src/main/resources/META-INF/plugin.xml',
    RegExp(r'<version>[^<]+</version>'),
    '<version>$version</version>');
  print('  ✓ intellij-plugin/plugin.xml');

  // README.md
  updateFile('$root/README.md',
    RegExp(r'flutter_skill:\s*\^[\d.]+'),
    'flutter_skill: ^$version',
    all: true);
  print('  ✓ README.md');
}

void updateFile(String path, RegExp pattern, String replacement, {bool all = false}) {
  final file = File(path);
  if (!file.existsSync()) return;

  var content = file.readAsStringSync();
  if (all) {
    content = content.replaceAll(pattern, replacement);
  } else {
    content = content.replaceFirst(pattern, replacement);
  }
  file.writeAsStringSync(content);
}

void updateChangelog(String root, String version, String description) {
  final file = File('$root/CHANGELOG.md');
  final existing = file.existsSync() ? file.readAsStringSync() : '';

  final entry = '''## $version

**$description**

### Changes
- TODO: Add your changes here

---

''';

  file.writeAsStringSync(entry + existing);
  print('  ✓ Added $version entry');
  print('  ⚠️  Edit CHANGELOG.md to add release details before confirming');
}
