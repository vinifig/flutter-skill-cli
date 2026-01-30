#!/usr/bin/env dart
/// Syncs version from pubspec.yaml to all distribution packages.
///
/// Usage:
///   dart scripts/sync_version.dart           # Sync current version
///   dart scripts/sync_version.dart 0.2.16    # Set and sync new version

import 'dart:io';

void main(List<String> args) {
  final projectRoot = Directory.current.path;

  // Get version from argument or pubspec.yaml
  String version;
  if (args.isNotEmpty) {
    version = args[0];
    // Update pubspec.yaml first
    updatePubspec(projectRoot, version);
  } else {
    version = readPubspecVersion(projectRoot);
  }

  print('📦 Syncing version: $version\n');

  // Update all distribution packages
  final updates = [
    () => updateNpmPackage(projectRoot, version),
    () => updateVscodePackage(projectRoot, version),
    () => updateIntellijPlugin(projectRoot, version),
    () => updateReadmeVersion(projectRoot, version),
  ];

  int success = 0;
  for (final update in updates) {
    if (update()) success++;
  }

  print('\n✅ Updated $success/${updates.length} files');
  print('📝 Don\'t forget to update CHANGELOG.md manually');
}

String readPubspecVersion(String root) {
  final file = File('$root/pubspec.yaml');
  final content = file.readAsStringSync();
  final match = RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(content);
  if (match == null) {
    throw Exception('Could not find version in pubspec.yaml');
  }
  return match.group(1)!.trim();
}

void updatePubspec(String root, String version) {
  final file = File('$root/pubspec.yaml');
  var content = file.readAsStringSync();
  content = content.replaceFirst(
    RegExp(r'^version:\s*.+$', multiLine: true),
    'version: $version',
  );
  file.writeAsStringSync(content);
  print('✓ pubspec.yaml → $version');
}

bool updateNpmPackage(String root, String version) {
  return updateJsonVersion('$root/npm/package.json', version);
}

bool updateVscodePackage(String root, String version) {
  return updateJsonVersion('$root/vscode-extension/package.json', version);
}

bool updateJsonVersion(String path, String version) {
  final file = File(path);
  if (!file.existsSync()) {
    print('✗ ${file.path} (not found)');
    return false;
  }

  var content = file.readAsStringSync();
  content = content.replaceFirst(
    RegExp(r'"version":\s*"[^"]+"'),
    '"version": "$version"',
  );
  file.writeAsStringSync(content);

  final name = path.split('/').last;
  print('✓ $name → $version');
  return true;
}

bool updateIntellijPlugin(String root, String version) {
  // Update build.gradle.kts
  final gradleFile = File('$root/intellij-plugin/build.gradle.kts');
  if (gradleFile.existsSync()) {
    var content = gradleFile.readAsStringSync();
    content = content.replaceFirst(
      RegExp(r'version\s*=\s*"[^"]+"'),
      'version = "$version"',
    );
    gradleFile.writeAsStringSync(content);
    print('✓ build.gradle.kts → $version');
  }

  // Update plugin.xml
  final pluginXml = File('$root/intellij-plugin/src/main/resources/META-INF/plugin.xml');
  if (pluginXml.existsSync()) {
    var content = pluginXml.readAsStringSync();
    content = content.replaceFirst(
      RegExp(r'<version>[^<]+</version>'),
      '<version>$version</version>',
    );
    pluginXml.writeAsStringSync(content);
    print('✓ plugin.xml → $version');
  }

  return true;
}

bool updateReadmeVersion(String root, String version) {
  final file = File('$root/README.md');
  if (!file.existsSync()) return false;

  var content = file.readAsStringSync();
  // Update flutter_skill: ^x.x.x in README
  content = content.replaceAll(
    RegExp(r'flutter_skill:\s*\^[\d.]+'),
    'flutter_skill: ^$version',
  );
  file.writeAsStringSync(content);
  print('✓ README.md → flutter_skill: ^$version');
  return true;
}
