import 'dart:io';
import 'dart:convert';

/// Detected project platform.
enum ProjectPlatform {
  flutter,
  ios,
  android,
  reactNative,
  web,
  unknown,
}

/// Auto-detect project type and set up flutter-skill bridge.
Future<void> runInit(List<String> args) async {
  final projectPath = args.isNotEmpty ? args[0] : '.';
  final dir = Directory(projectPath);

  if (!dir.existsSync()) {
    print('❌ Directory not found: $projectPath');
    exit(1);
  }

  final absPath = dir.absolute.path;
  print('');
  print('🔍 Detecting project type in: $absPath');
  print('');

  final platform = _detectPlatform(absPath);

  if (platform == ProjectPlatform.unknown) {
    print('❌ Could not detect project type.');
    print('');
    print('Supported project types:');
    print('  • Flutter  (pubspec.yaml with flutter dependency)');
    print('  • iOS      (Package.swift or *.xcodeproj)');
    print('  • Android  (build.gradle or build.gradle.kts)');
    print('  • React Native (package.json with react-native)');
    print('  • Web      (index.html)');
    exit(1);
  }

  print('✅ Detected: ${_platformName(platform)}');
  print('');

  switch (platform) {
    case ProjectPlatform.flutter:
      await _setupFlutter(absPath);
      break;
    case ProjectPlatform.ios:
      await _setupIOS(absPath);
      break;
    case ProjectPlatform.android:
      await _setupAndroid(absPath);
      break;
    case ProjectPlatform.reactNative:
      await _setupReactNative(absPath);
      break;
    case ProjectPlatform.web:
      await _setupWeb(absPath);
      break;
    default:
      break;
  }

  // Auto-configure MCP for AI agents
  await _configureMCP();

  print('');
  print('═══════════════════════════════════════════════════');
  print('  🎉 Setup complete!');
  print('');
  print('  Next steps:');
  print('    1. Run your app');
  print('    2. Tell your AI agent:');
  print('       "Test my app - tap buttons and verify the UI"');
  print('');
  print('  Or use the CLI:');
  print('    flutter-skill launch $projectPath');
  print('═══════════════════════════════════════════════════');
  print('');
}

ProjectPlatform _detectPlatform(String path) {
  // Check Flutter first (most common)
  final pubspec = File('$path/pubspec.yaml');
  if (pubspec.existsSync()) {
    final content = pubspec.readAsStringSync();
    if (content.contains('flutter:') || content.contains('flutter_skill:')) {
      return ProjectPlatform.flutter;
    }
  }

  // React Native (check before generic web)
  final packageJson = File('$path/package.json');
  if (packageJson.existsSync()) {
    try {
      final content = jsonDecode(packageJson.readAsStringSync()) as Map;
      final deps = content['dependencies'] as Map? ?? {};
      final devDeps = content['devDependencies'] as Map? ?? {};
      if (deps.containsKey('react-native') || devDeps.containsKey('react-native')) {
        return ProjectPlatform.reactNative;
      }
    } catch (_) {}
  }

  // iOS
  final packageSwift = File('$path/Package.swift');
  if (packageSwift.existsSync()) return ProjectPlatform.ios;
  final xcodeProj = Directory(path).listSync().any(
      (e) => e.path.endsWith('.xcodeproj') || e.path.endsWith('.xcworkspace'));
  if (xcodeProj) return ProjectPlatform.ios;

  // Android
  final buildGradle = File('$path/build.gradle');
  final buildGradleKts = File('$path/build.gradle.kts');
  if (buildGradle.existsSync() || buildGradleKts.existsSync()) {
    return ProjectPlatform.android;
  }

  // Web (generic)
  final indexHtml = File('$path/index.html');
  final webIndexHtml = File('$path/web/index.html');
  final publicIndexHtml = File('$path/public/index.html');
  if (indexHtml.existsSync() ||
      webIndexHtml.existsSync() ||
      publicIndexHtml.existsSync()) {
    return ProjectPlatform.web;
  }

  return ProjectPlatform.unknown;
}

String _platformName(ProjectPlatform platform) {
  switch (platform) {
    case ProjectPlatform.flutter:
      return '🐦 Flutter (Dart)';
    case ProjectPlatform.ios:
      return '🍎 iOS (Swift)';
    case ProjectPlatform.android:
      return '🤖 Android (Kotlin)';
    case ProjectPlatform.reactNative:
      return '⚛️  React Native';
    case ProjectPlatform.web:
      return '🌐 Web';
    default:
      return 'Unknown';
  }
}

// ─── Flutter Setup ───────────────────────────────────────────────

Future<void> _setupFlutter(String path) async {
  print('📦 Adding flutter_skill dependency...');

  final pubspec = File('$path/pubspec.yaml');
  final content = pubspec.readAsStringSync();

  if (!content.contains('flutter_skill:')) {
    final result = await Process.run(
      'flutter', ['pub', 'add', 'flutter_skill'],
      workingDirectory: path,
    );
    if (result.exitCode != 0) {
      print('⚠️  Could not add dependency automatically.');
      print('   Add manually: flutter pub add flutter_skill');
    } else {
      print('   ✅ Dependency added');
    }
  } else {
    print('   ✅ Dependency already present');
  }

  // Patch main.dart
  final mainFile = File('$path/lib/main.dart');
  if (!mainFile.existsSync()) {
    print('⚠️  lib/main.dart not found — skipping auto-patch');
    return;
  }

  var mainContent = mainFile.readAsStringSync();
  bool changed = false;

  if (!mainContent.contains('package:flutter_skill/flutter_skill.dart')) {
    mainContent =
        "import 'package:flutter_skill/flutter_skill.dart';\nimport 'package:flutter/foundation.dart';\n$mainContent";
    changed = true;
  }

  if (!mainContent.contains('FlutterSkillBinding.ensureInitialized()')) {
    final mainRegex = RegExp(r'void\s+main\s*\(\s*\)\s*(async\s*)?\{');
    final match = mainRegex.firstMatch(mainContent);
    if (match != null) {
      const injection =
          '\n  if (kDebugMode) { FlutterSkillBinding.ensureInitialized(); }\n';
      mainContent = mainContent.replaceRange(match.end, match.end, injection);
      changed = true;
    }
  }

  if (changed) {
    mainFile.writeAsStringSync(mainContent);
    print('   ✅ main.dart patched');
  } else {
    print('   ✅ main.dart already configured');
  }
}

// ─── iOS Setup ───────────────────────────────────────────────────

Future<void> _setupIOS(String path) async {
  print('📦 Setting up iOS SDK...');

  // Check if already has the import
  final appDelegate = _findFile(path, ['AppDelegate.swift']);
  final swiftUIApp = _findSwiftUIEntryPoint(path);
  final entryFile = appDelegate ?? swiftUIApp;

  if (entryFile == null) {
    print('   ℹ️  No AppDelegate.swift or @main App found.');
    print('   Add manually to your entry point:');
    print('');
    print('   import FlutterSkill');
    print('   FlutterSkillBridge.shared.start()');
    return;
  }

  var content = entryFile.readAsStringSync();
  bool changed = false;

  if (!content.contains('import FlutterSkill')) {
    // Add import after the last import line
    final importRegex = RegExp(r'(import \w+\n)(?!import)');
    final match = importRegex.firstMatch(content);
    if (match != null) {
      content = content.replaceRange(
          match.end, match.end, 'import FlutterSkill\n');
      changed = true;
    }
  }

  if (!content.contains('FlutterSkillBridge')) {
    // Add start call
    if (content.contains('didFinishLaunchingWithOptions')) {
      // UIKit AppDelegate
      final launchRegex =
          RegExp(r'didFinishLaunchingWithOptions[^{]*\{');
      final match = launchRegex.firstMatch(content);
      if (match != null) {
        content = content.replaceRange(match.end, match.end,
            '\n        #if DEBUG\n        FlutterSkillBridge.shared.start()\n        #endif\n');
        changed = true;
      }
    } else if (content.contains('var body:')) {
      // SwiftUI App
      final bodyRegex = RegExp(r'var body:\s*some\s+Scene\s*\{');
      final match = bodyRegex.firstMatch(content);
      if (match != null) {
        content = content.replaceRange(match.start, match.start,
            '    init() {\n        #if DEBUG\n        FlutterSkillBridge.shared.start()\n        #endif\n    }\n\n    ');
        changed = true;
      }
    }
  }

  if (changed) {
    entryFile.writeAsStringSync(content);
    print('   ✅ ${entryFile.path.split('/').last} patched');
  } else {
    print('   ✅ Already configured');
  }

  print('');
  print('   📎 Add the Swift Package in Xcode:');
  print('   File → Add Package → https://github.com/ai-dashboad/flutter-skill');
  print('   Select the "FlutterSkill" library from sdks/ios');
}

// ─── Android Setup ───────────────────────────────────────────────

Future<void> _setupAndroid(String path) async {
  print('📦 Setting up Android SDK...');

  // Find MainActivity
  final mainActivity = _findFile(path, [
    'app/src/main/java/com',
    'app/src/main/kotlin/com',
  ]);

  // Try to find MainActivity.kt
  File? activityFile;
  try {
    activityFile = _findFileRecursive(path, 'MainActivity.kt') ??
        _findFileRecursive(path, 'MainActivity.java');
  } catch (_) {}

  if (activityFile == null) {
    print('   ℹ️  MainActivity not found.');
    print('   Add manually to your Activity:');
    print('');
    print('   import com.flutterskill.FlutterSkillBridge');
    print('   FlutterSkillBridge.start(this)');
    return;
  }

  var content = activityFile.readAsStringSync();
  bool changed = false;

  if (!content.contains('FlutterSkillBridge')) {
    // Add import
    if (!content.contains('import com.flutterskill')) {
      final importRegex = RegExp(r'(import [^\n]+\n)(?!import)');
      final match = importRegex.firstMatch(content);
      if (match != null) {
        content = content.replaceRange(
            match.end, match.end, 'import com.flutterskill.FlutterSkillBridge\n');
        changed = true;
      }
    }

    // Add start call in onCreate
    final onCreateRegex = RegExp(r'super\.onCreate\([^)]*\)');
    final match = onCreateRegex.firstMatch(content);
    if (match != null) {
      content = content.replaceRange(match.end, match.end,
          '\n        if (BuildConfig.DEBUG) { FlutterSkillBridge.start(this) }');
      changed = true;
    }
  }

  if (changed) {
    activityFile.writeAsStringSync(content);
    print('   ✅ ${activityFile.path.split('/').last} patched');
  } else {
    print('   ✅ Already configured');
  }

  print('');
  print('   📎 Add the Gradle dependency:');
  print('   implementation("com.flutterskill:flutter-skill:0.7.3")');
}

// ─── React Native Setup ──────────────────────────────────────────

Future<void> _setupReactNative(String path) async {
  print('📦 Setting up React Native SDK...');

  // npm install
  print('   Installing flutter-skill npm package...');
  final result = await Process.run('npm', ['install', 'flutter-skill'],
      workingDirectory: path);
  if (result.exitCode != 0) {
    print('   ⚠️  npm install failed. Add manually: npm install flutter-skill');
  } else {
    print('   ✅ Package installed');
  }

  // Patch entry point
  final entryFiles = ['index.js', 'App.js', 'App.tsx'];
  File? entryFile;
  for (final name in entryFiles) {
    final f = File('$path/$name');
    if (f.existsSync()) {
      entryFile = f;
      break;
    }
  }

  if (entryFile == null) {
    print('   ℹ️  Entry point not found. Add manually:');
    print("   import FlutterSkill from 'flutter-skill';");
    print('   FlutterSkill.start();');
    return;
  }

  var content = entryFile.readAsStringSync();
  if (!content.contains('flutter-skill')) {
    content =
        "import FlutterSkill from 'flutter-skill';\nFlutterSkill.start();\n\n$content";
    entryFile.writeAsStringSync(content);
    print('   ✅ ${entryFile.path.split('/').last} patched');
  } else {
    print('   ✅ Already configured');
  }
}

// ─── Web Setup ───────────────────────────────────────────────────

Future<void> _setupWeb(String path) async {
  print('📦 Setting up Web SDK...');

  // Find index.html
  final candidates = ['$path/index.html', '$path/web/index.html', '$path/public/index.html'];
  File? htmlFile;
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) {
      htmlFile = f;
      break;
    }
  }

  if (htmlFile == null) {
    print('   ℹ️  index.html not found.');
    print('   Add manually before </body>:');
    print('   <script src="https://unpkg.com/flutter-skill/flutter-skill.js"></script>');
    print('   <script>FlutterSkill.start();</script>');
    return;
  }

  var content = htmlFile.readAsStringSync();
  if (!content.contains('flutter-skill')) {
    final bodyClose = content.indexOf('</body>');
    if (bodyClose != -1) {
      const script = '''
  <script src="https://unpkg.com/flutter-skill/flutter-skill.js"></script>
  <script>FlutterSkill.start();</script>
  ''';
      content = content.replaceRange(bodyClose, bodyClose, script);
      htmlFile.writeAsStringSync(content);
      print('   ✅ ${htmlFile.path.split('/').last} patched');
    }
  } else {
    print('   ✅ Already configured');
  }
}

// ─── MCP Auto-Config ─────────────────────────────────────────────

Future<void> _configureMCP() async {
  print('🤖 Configuring AI agent MCP...');

  final home = Platform.environment['HOME'] ?? '';

  // Claude Code
  final claudeSettings = File('$home/.claude/settings.json');
  if (await _addMCPConfig(claudeSettings, 'Claude Code')) return;

  // Cursor
  final cursorMCP = File('$home/.cursor/mcp.json');
  if (await _addMCPConfig(cursorMCP, 'Cursor')) return;

  // If no agent config found, create Claude Code config
  print('   Creating Claude Code MCP config...');
  final claudeDir = Directory('$home/.claude');
  if (!claudeDir.existsSync()) claudeDir.createSync(recursive: true);

  final config = {
    'mcpServers': {
      'flutter-skill': {
        'command': 'flutter-skill',
        'args': ['server'],
      }
    }
  };

  if (claudeSettings.existsSync()) {
    try {
      final existing = jsonDecode(claudeSettings.readAsStringSync()) as Map;
      final servers = (existing['mcpServers'] as Map?) ?? {};
      if (!servers.containsKey('flutter-skill')) {
        servers['flutter-skill'] = config['mcpServers']!['flutter-skill'];
        existing['mcpServers'] = servers;
        claudeSettings.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(existing));
        print('   ✅ Claude Code MCP configured');
      } else {
        print('   ✅ Claude Code MCP already configured');
      }
    } catch (_) {
      print('   ⚠️  Could not parse existing settings');
    }
  } else {
    claudeSettings.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(config));
    print('   ✅ Claude Code MCP configured');
  }
}

Future<bool> _addMCPConfig(File configFile, String agentName) async {
  if (!configFile.existsSync()) return false;

  try {
    final content = jsonDecode(configFile.readAsStringSync()) as Map;
    final servers = (content['mcpServers'] as Map?) ?? {};
    if (servers.containsKey('flutter-skill')) {
      print('   ✅ $agentName MCP already configured');
      return true;
    }
    servers['flutter-skill'] = {
      'command': 'flutter-skill',
      'args': ['server'],
    };
    content['mcpServers'] = servers;
    configFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(content));
    print('   ✅ $agentName MCP configured');
    return true;
  } catch (_) {
    return false;
  }
}

// ─── Helpers ─────────────────────────────────────────────────────

File? _findFile(String basePath, List<String> candidates) {
  for (final c in candidates) {
    final f = File('$basePath/$c');
    if (f.existsSync()) return f;
  }
  return null;
}

File? _findFileRecursive(String basePath, String fileName) {
  final dir = Directory(basePath);
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith(fileName)) {
      return entity;
    }
  }
  return null;
}

File? _findSwiftUIEntryPoint(String path) {
  try {
    final dir = Directory(path);
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.swift')) {
        final content = entity.readAsStringSync();
        if (content.contains('@main') && content.contains('App')) {
          return entity;
        }
      }
    }
  } catch (_) {}
  return null;
}
