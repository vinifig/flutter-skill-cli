part of '../server.dart';

extension _CdpConnectionHandlers2 on FlutterMcpServer {
  /// CDP connection and project diagnostics
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleCdpConnectionTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'connect_cdp') {
      final url = args['url'] as String? ?? '';
      final port = args['port'] as int? ?? 9222;
      final launchChrome = args['launch_chrome'] ?? (url.isNotEmpty);
      final headless = args['headless'] ?? false;
      final chromePath = args['chrome_path'] as String?;
      final proxy = args['proxy'] as String?;
      final ignoreSsl = args['ignore_ssl'] ?? false;
      final maxTabs = args['max_tabs'] as int? ?? 20;

      // Disconnect existing CDP connection if any
      if (_cdpDriver != null) {
        await _cdpDriver!.disconnect();
        _cdpDriver = null;
      }

      try {
        final driver = CdpDriver(
          url: url,
          port: port,
          launchChrome: launchChrome,
          headless: headless,
          chromePath: chromePath,
          proxy: proxy,
          ignoreSsl: ignoreSsl,
          maxTabs: maxTabs,
        );
        await driver.connect();
        _cdpDriver = driver;

        // Also store as a session so tools that use _getClient can find it
        final sessionId = 'cdp_${DateTime.now().millisecondsSinceEpoch}';
        _clients[sessionId] = driver;
        _sessions[sessionId] = SessionInfo(
          id: sessionId,
          name: 'CDP: $url',
          projectPath: url,
          deviceId: 'chrome',
          port: port,
          vmServiceUri: 'cdp://127.0.0.1:$port',
        );
        _activeSessionId = sessionId;

        return {
          "success": true,
          "mode": "cdp",
          "url": url,
          "port": port,
          "session_id": sessionId,
          "message": "Connected to $url via CDP on port $port",
          "note": "If Chrome was already running without remote debugging, "
              "flutter-skill auto-launched a debug-enabled profile alongside it.",
        };
      } catch (e) {
        return {
          "success": false,
          "error": {
            "code": "E601",
            "message": "CDP connection failed: $e",
          },
          "suggestions": [
            "Ensure Chrome is installed",
            "Let flutter-skill auto-launch Chrome: connect_cdp(url: '$url')",
            "Or point to an existing Chrome with debugging already on: "
                "connect_cdp(url: '$url', launch_chrome: false)",
            "Manual launch: google-chrome --remote-debugging-port=$port "
                "--user-data-dir=/tmp/chrome-debug",
          ],
        };
      }
    }

    if (name == 'diagnose_project') {
      final projectPath = args['project_path'] ?? '.';
      final autoFix = args['auto_fix'] ?? true;

      final diagnosticResult = <String, dynamic>{
        "project_path": projectPath,
        "checks": <String, dynamic>{},
        "issues": <String>[],
        "fixes_applied": <String>[],
        "recommendations": <String>[],
      };

      // Check pubspec.yaml
      final pubspecFile = File('$projectPath/pubspec.yaml');
      if (pubspecFile.existsSync()) {
        final pubspecContent = pubspecFile.readAsStringSync();
        final hasDependency = pubspecContent.contains('flutter_skill:');

        diagnosticResult['checks']['pubspec_yaml'] = {
          "status": hasDependency ? "ok" : "missing_dependency",
          "message": hasDependency
              ? "flutter_skill dependency found"
              : "flutter_skill dependency missing",
        };

        if (!hasDependency) {
          diagnosticResult['issues']
              .add("Missing flutter_skill dependency in pubspec.yaml");
          if (autoFix) {
            try {
              await runSetup(projectPath);
              diagnosticResult['fixes_applied']
                  .add("Added flutter_skill dependency to pubspec.yaml");
            } catch (e) {
              diagnosticResult['fixes_applied']
                  .add("Failed to add dependency: $e");
            }
          } else {
            diagnosticResult['recommendations']
                .add("Run: flutter pub add flutter_skill");
          }
        }
      } else {
        diagnosticResult['checks']['pubspec_yaml'] = {
          "status": "not_found",
          "message": "pubspec.yaml not found - not a Flutter project?",
        };
        diagnosticResult['issues']
            .add("pubspec.yaml not found at $projectPath");
      }

      // Check lib/main.dart
      final mainFile = File('$projectPath/lib/main.dart');
      if (mainFile.existsSync()) {
        final mainContent = mainFile.readAsStringSync();
        final hasImport =
            mainContent.contains('package:flutter_skill/flutter_skill.dart');
        final hasInit =
            mainContent.contains('FlutterSkillBinding.ensureInitialized()');

        diagnosticResult['checks']['main_dart'] = {
          "has_import": hasImport,
          "has_initialization": hasInit,
          "status": (hasImport && hasInit) ? "ok" : "incomplete",
          "message": (hasImport && hasInit)
              ? "FlutterSkillBinding properly configured"
              : "FlutterSkillBinding not properly initialized",
        };

        if (!hasImport || !hasInit) {
          if (!hasImport)
            diagnosticResult['issues']
                .add("Missing flutter_skill import in lib/main.dart");
          if (!hasInit)
            diagnosticResult['issues'].add(
                "Missing FlutterSkillBinding initialization in lib/main.dart");

          if (autoFix) {
            try {
              await runSetup(projectPath);
              diagnosticResult['fixes_applied'].add(
                  "Added FlutterSkillBinding initialization to lib/main.dart");
            } catch (e) {
              diagnosticResult['fixes_applied']
                  .add("Failed to update main.dart: $e");
            }
          } else {
            diagnosticResult['recommendations'].add(
                "Add to main.dart: FlutterSkillBinding.ensureInitialized()");
          }
        }
      } else {
        diagnosticResult['checks']['main_dart'] = {
          "status": "not_found",
          "message": "lib/main.dart not found",
        };
        diagnosticResult['issues'].add("lib/main.dart not found");
      }

      // Check running Flutter processes
      try {
        final result = await Process.run('pgrep', ['-f', 'flutter']);
        final hasRunningFlutter =
            result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty;

        diagnosticResult['checks']['running_processes'] = {
          "flutter_running": hasRunningFlutter,
          "message": hasRunningFlutter
              ? "Flutter process detected"
              : "No Flutter process running",
        };

        if (!hasRunningFlutter) {
          diagnosticResult['recommendations']
              .add("Start your Flutter app with: flutter_skill launch .");
        }
      } catch (e) {
        diagnosticResult['checks']['running_processes'] = {
          "error": "Could not check processes: $e",
        };
      }

      // Check port availability
      final portsToCheck = [50000, 50001, 50002];
      final portStatus = <String, dynamic>{};

      for (final port in portsToCheck) {
        try {
          final result = await Process.run('lsof', ['-i', ':$port']);
          final inUse = result.exitCode == 0;
          portStatus['port_$port'] = inUse ? "in_use" : "available";
        } catch (e) {
          portStatus['port_$port'] = "unknown";
        }
      }

      diagnosticResult['checks']['ports'] = portStatus;

      // Generate summary
      final issueCount = (diagnosticResult['issues'] as List).length;
      final fixCount = (diagnosticResult['fixes_applied'] as List).length;

      diagnosticResult['summary'] = {
        "status": issueCount == 0
            ? "healthy"
            : (fixCount > 0 ? "fixed" : "needs_attention"),
        "issues_found": issueCount,
        "fixes_applied": fixCount,
        "message": issueCount == 0
            ? "✅ Project is properly configured"
            : (fixCount > 0
                ? "🔧 Fixed $fixCount issue(s), please restart your app"
                : "⚠️ Found $issueCount issue(s), run with auto_fix:true to fix"),
      };

      return diagnosticResult;
    }

    return null; // Not handled by this group
  }
}
