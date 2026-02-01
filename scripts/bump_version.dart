#!/usr/bin/env dart
/// Unified version bumping script for all distribution channels
///
/// Usage:
///   dart scripts/bump_version.dart <new_version>
///   dart scripts/bump_version.dart 0.2.22
///
/// Updates:
///   - pubspec.yaml
///   - npm/package.json
///   - vscode-extension/package.json
///   - intellij-plugin/build.gradle.kts

import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    print('Error: Version number required');
    print('Usage: dart scripts/bump_version.dart <version>');
    print('Example: dart scripts/bump_version.dart 0.2.22');
    exit(1);
  }

  final version = args[0];

  // Validate version format (semantic versioning)
  final versionRegex = RegExp(r'^\d+\.\d+\.\d+(-[\w.]+)?$');
  if (!versionRegex.hasMatch(version)) {
    print('Error: Invalid version format. Expected: x.y.z or x.y.z-suffix');
    print('Got: $version');
    exit(1);
  }

  print('Updating all distribution channels to version $version\n');

  final results = <String, bool>{};

  // Update pubspec.yaml
  results['pubspec.yaml'] = updatePubspec(version);

  // Update npm/package.json
  results['npm/package.json'] = updatePackageJson('npm/package.json', version);

  // Update vscode-extension/package.json
  results['vscode-extension/package.json'] =
      updatePackageJson('vscode-extension/package.json', version);

  // Update intellij-plugin/build.gradle.kts
  results['intellij-plugin/build.gradle.kts'] = updateGradleKts(version);

  // Print summary
  print('\n' + '═' * 60);
  print('VERSION BUMP SUMMARY');
  print('═' * 60);

  var allSuccess = true;
  results.forEach((file, success) {
    final status = success ? '✅' : '❌';
    print('$status $file');
    if (!success) allSuccess = false;
  });

  print('═' * 60);

  if (allSuccess) {
    print('\n✅ All files updated successfully!');
    print('\nNext steps:');
    print('  1. Review changes: git diff');
    print('  2. Commit: git add -A && git commit -m "chore: Bump version to $version"');
    print('  3. Tag: git tag v$version');
    print('  4. Push: git push origin main --tags');
    exit(0);
  } else {
    print('\n❌ Some files failed to update. Please check manually.');
    exit(1);
  }
}

bool updatePubspec(String version) {
  try {
    final file = File('pubspec.yaml');
    if (!file.existsSync()) {
      print('❌ pubspec.yaml not found');
      return false;
    }

    var content = file.readAsStringSync();
    final oldVersionMatch = RegExp(r'^version:\s*(.+)$', multiLine: true)
        .firstMatch(content);

    if (oldVersionMatch == null) {
      print('❌ Could not find version in pubspec.yaml');
      return false;
    }

    final oldVersion = oldVersionMatch.group(1)!.trim();
    content = content.replaceFirst(
      RegExp(r'^version:.*$', multiLine: true),
      'version: $version',
    );

    file.writeAsStringSync(content);
    print('✅ pubspec.yaml: $oldVersion → $version');
    return true;
  } catch (e) {
    print('❌ Error updating pubspec.yaml: $e');
    return false;
  }
}

bool updatePackageJson(String path, String version) {
  try {
    final file = File(path);
    if (!file.existsSync()) {
      print('❌ $path not found');
      return false;
    }

    var content = file.readAsStringSync();
    final oldVersionMatch = RegExp(r'"version":\s*"([^"]+)"')
        .firstMatch(content);

    if (oldVersionMatch == null) {
      print('❌ Could not find version in $path');
      return false;
    }

    final oldVersion = oldVersionMatch.group(1)!;
    content = content.replaceFirst(
      RegExp(r'"version":\s*"[^"]+"'),
      '"version": "$version"',
    );

    file.writeAsStringSync(content);
    print('✅ $path: $oldVersion → $version');
    return true;
  } catch (e) {
    print('❌ Error updating $path: $e');
    return false;
  }
}

bool updateGradleKts(String version) {
  try {
    final file = File('intellij-plugin/build.gradle.kts');
    if (!file.existsSync()) {
      print('❌ intellij-plugin/build.gradle.kts not found');
      return false;
    }

    var content = file.readAsStringSync();
    final oldVersionMatch = RegExp(r'^version\s*=\s*"([^"]+)"', multiLine: true)
        .firstMatch(content);

    if (oldVersionMatch == null) {
      print('❌ Could not find version in build.gradle.kts');
      return false;
    }

    final oldVersion = oldVersionMatch.group(1)!;
    content = content.replaceFirst(
      RegExp(r'^version\s*=\s*"[^"]+"', multiLine: true),
      'version = "$version"',
    );

    file.writeAsStringSync(content);
    print('✅ intellij-plugin/build.gradle.kts: $oldVersion → $version');
    return true;
  } catch (e) {
    print('❌ Error updating build.gradle.kts: $e');
    return false;
  }
}