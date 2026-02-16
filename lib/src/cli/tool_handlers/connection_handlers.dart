part of '../server.dart';

extension _ConnectionHandlers on FlutterMcpServer {
  /// Connection, session, and HTTP tools
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleConnectionTools(String name, Map<String, dynamic> args) async {
    // Session management tools
    if (name == 'list_sessions') {
      return {
        "sessions": _sessions.values.map((s) => s.toJson()).toList(),
        "active_session_id": _activeSessionId,
        "count": _sessions.length,
      };
    }

    if (name == 'switch_session') {
      final sessionId = args['session_id'] as String?;
      if (sessionId == null) {
        return {
          "success": false,
          "error": {"code": "E401", "message": "session_id is required"},
        };
      }

      if (!_sessions.containsKey(sessionId)) {
        return {
          "success": false,
          "error": {
            "code": "E402",
            "message": "Session not found: $sessionId",
          },
          "available_sessions": _sessions.keys.toList(),
        };
      }

      _activeSessionId = sessionId;
      return {
        "success": true,
        "message": "Switched to session $sessionId",
        "session": _sessions[sessionId]!.toJson(),
      };
    }

    if (name == 'close_session') {
      final sessionId = args['session_id'] as String?;
      if (sessionId == null) {
        return {
          "success": false,
          "error": {"code": "E401", "message": "session_id is required"},
        };
      }

      if (!_sessions.containsKey(sessionId)) {
        return {
          "success": false,
          "error": {
            "code": "E402",
            "message": "Session not found: $sessionId",
          },
        };
      }

      // Disconnect and remove client
      final client = _clients[sessionId];
      if (client != null) {
        await client.disconnect();
        _clients.remove(sessionId);
      }

      // Remove session
      _sessions.remove(sessionId);

      // Update active session
      if (_activeSessionId == sessionId) {
        _activeSessionId =
            _sessions.keys.isNotEmpty ? _sessions.keys.first : null;
      }

      return {
        "success": true,
        "message": "Closed session $sessionId",
        "active_session_id": _activeSessionId,
        "remaining_sessions": _sessions.length,
      };
    }

    // Connection tools
    if (name == 'connect_app') {
      var uri = args['uri'] as String;

      // Auto-fix configuration if project_path is provided
      final projectPath = args['project_path'] as String?;
      if (projectPath != null) {
        try {
          await runSetup(projectPath);
        } catch (e) {
          // Continue even if setup fails
          print('Warning: Auto-setup failed: $e');
        }
      }

      // Normalize URI format
      uri = _normalizeVmServiceUri(uri);

      // Create a new session for this connection
      final sessionId = args['session_id'] as String? ?? _generateSessionId();

      // If session already exists, disconnect it first
      if (_clients.containsKey(sessionId)) {
        await _clients[sessionId]!.disconnect();
      }

      // Retry logic with exponential backoff
      const maxRetries = 3;
      Exception? lastError;

      for (var attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          final client = FlutterSkillClient(uri);
          await client.connect();

          // Store client and session info
          _clients[sessionId] = client;
          _sessions[sessionId] = SessionInfo(
            id: sessionId,
            name:
                args['name'] as String? ?? 'Connection ${_sessions.length + 1}',
            projectPath: args['project_path'] as String? ?? 'unknown',
            deviceId: args['device_id'] as String? ?? 'unknown',
            port: int.tryParse(uri.split(':').last.split('/').first) ?? 0,
            vmServiceUri: uri,
          );

          // Always switch to the newly created session
          _activeSessionId = sessionId;

          // Store for auto-reconnect
          _lastConnectionUri = uri;
          _lastConnectionPort = int.tryParse(uri.split(':').last.split('/').first);

          return {
            "success": true,
            "message": "Connected to $uri",
            "uri": uri,
            "session_id": sessionId,
            "active_session": true,
            "attempts": attempt,
          };
        } catch (e) {
          lastError = e is Exception ? e : Exception(e.toString());
          _clients.remove(sessionId);

          if (attempt < maxRetries) {
            // Wait before retry (100ms, 200ms, 400ms)
            await Future.delayed(
                Duration(milliseconds: 100 * (1 << (attempt - 1))));
          }
        }
      }

      return {
        "success": false,
        "error": {
          "code": "E201",
          "message": "Failed to connect after $maxRetries attempts: $lastError",
        },
        "uri": uri,
        "suggestions": [
          "Verify the app is running with 'flutter run'",
          "Check if the VM Service URI is correct",
          "Try scan_and_connect() to auto-detect running apps",
        ],
      };
    }

    if (name == 'launch_app') {
      final projectPath = args['project_path'] ?? '.';
      final deviceId = args['device_id'];
      final dartDefines = args['dart_defines'] as List<dynamic>?;
      final extraArgs = args['extra_args'] as List<dynamic>?;
      final flavor = args['flavor'];
      final target = args['target'];

      // Generate session ID for this launch
      final sessionId = args['session_id'] as String? ?? _generateSessionId();

      // If this session already has a running app, kill it
      if (_clients.containsKey(sessionId)) {
        await _clients[sessionId]!.disconnect();
        _clients.remove(sessionId);
      }

      if (_flutterProcess != null) {
        _flutterProcess!.kill();
        _flutterProcess = null;
      }

      final processArgs = ['run'];
      if (deviceId != null) processArgs.addAll(['-d', deviceId]);
      if (flavor != null) processArgs.addAll(['--flavor', flavor]);
      if (target != null) processArgs.addAll(['-t', target]);

      // Add dart defines
      if (dartDefines != null) {
        for (final define in dartDefines) {
          processArgs.addAll(['--dart-define', define.toString()]);
        }
      }

      // Add extra arguments
      if (extraArgs != null) {
        for (final arg in extraArgs) {
          processArgs.add(arg.toString());
        }
      }

      try {
        await runSetup(projectPath);
      } catch (e) {
        // Continue even if setup fails
      }

      _flutterProcess = await Process.start('flutter', processArgs,
          workingDirectory: projectPath);

      final completer = Completer<String>();
      final errorLines = <String>[];
      String? dtdUri; // Store DTD URI as fallback

      // Capture stdout (includes Flutter output and errors)
      _flutterProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        // Priority 1: Look for VM Service URI (http://.../)
        // Example: "The Dart VM service is listening on http://127.0.0.1:50753/xxxx=/" (Flutter 3.x)
        // Example: "The Dart VM service is listening on http://127.0.0.1:50753/xxxx#" (Flutter 3.41+)
        if (line.contains('VM service') || line.contains('Observatory')) {
          final vmRegex = RegExp(r'http://[a-zA-Z0-9.:\-_/=#]+[/#]?');
          final match = vmRegex.firstMatch(line);
          if (match != null && !completer.isCompleted) {
            final uri = match.group(0)!;

            // Disconnect old client for this session if exists
            if (_clients.containsKey(sessionId)) {
              _clients[sessionId]!.disconnect();
            }

            // Create new client and session
            final client = FlutterSkillClient(uri);
            client.connect().then((_) {
              // Store client and session info
              _clients[sessionId] = client;
              _sessions[sessionId] = SessionInfo(
                id: sessionId,
                name:
                    args['name'] as String? ?? 'App on ${deviceId ?? 'device'}',
                projectPath: projectPath,
                deviceId: deviceId?.toString() ?? 'unknown',
                port: int.tryParse(uri.split(':').last.split('/').first) ?? 0,
                vmServiceUri: uri,
              );

              // Always switch to the newly launched session
              _activeSessionId = sessionId;

              completer.complete("Launched and connected to $uri");
            }).catchError((e) {
              completer.completeError(
                  "Found VM Service URI but failed to connect: $e");
            });
            return; // Found VM Service URI, skip DTD check
          }
        }

        // Priority 2: DTD URI as fallback (ws://...=/ws)
        // Example: "ws://127.0.0.1:57868/8LD1UdC8wrc=/ws"
        if (line.contains('ws://') && line.contains('=/ws')) {
          final dtdRegex = RegExp(r'ws://[a-zA-Z0-9.:\-_/=]+/ws');
          final match = dtdRegex.firstMatch(line);
          if (match != null) {
            dtdUri = match.group(0)!;
            // Don't connect yet, wait for VM Service URI
            // If no VM Service URI found after 5 seconds, will timeout with helpful message
          }
        }

        // Capture error messages from Flutter output
        if (line.contains('[Flutter Error]') ||
            line.contains('Error:') ||
            line.contains('Exception:') ||
            line.contains('Failed to build') ||
            line.contains('Error launching application')) {
          errorLines.add(line);
        }
      });

      // Capture stderr (build errors, warnings)
      _flutterProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        // Collect all stderr output as potential errors
        if (line.trim().isNotEmpty) {
          errorLines.add(line);
        }
      });

      _flutterProcess!.exitCode.then((code) {
        if (!completer.isCompleted) {
          if (code != 0) {
            // Build failed, create detailed error response
            final errorMessage = errorLines.isNotEmpty
                ? errorLines.join('\n')
                : "Flutter app exited with code $code";

            // Build failed, complete with error marker
            completer.completeError({
              "success": false,
              "error": {
                "code": "E302",
                "message": "Flutter build/launch failed",
                "details": errorMessage,
                "exitCode": code,
              },
              "suggestions": _getBuildErrorSuggestions(errorMessage),
              "quick_fixes": _getQuickFixes(errorMessage, projectPath),
            });
          } else {
            completer.completeError(
                "Flutter app exited normally but no connection established");
          }
        }
        _flutterProcess = null;
      });

      try {
        final result = await completer.future
            .timeout(const Duration(seconds: 180)); // 3 minutes for slow builds
        return {
          "success": true,
          "message": result,
          "session_id": sessionId,
          "uri": _sessions[sessionId]?.vmServiceUri,
        };
      } on TimeoutException {
        // Check if we found DTD URI but no VM Service URI
        if (dtdUri != null) {
          return {
            "success": false,
            "error": {
              "code": "E301",
              "message": "Found DTD URI but no VM Service URI",
              "details":
                  "Flutter 3.x uses DTD protocol by default. VM Service URI not found in output.",
            },
            "found_uris": {"dtd": dtdUri},
            "suggestions": [
              "Flutter Skill requires VM Service URI, not DTD URI",
              "",
              "Option 1: Force VM Service protocol (recommended)",
              "Add to your flutter run command:",
              "  flutter run --vm-service-port=50000",
              "",
              "Option 2: Use Dart MCP for DTD-based testing",
              "  mcp__dart__connect_dart_tooling_daemon(uri: '$dtdUri')",
              "",
              "Option 3: Enable both protocols",
              "Check Flutter DevTools output for VM Service URI",
            ],
            "quick_fix":
                "Launch with: flutter run -d <device> --vm-service-port=50000",
          };
        }

        return {
          "success": false,
          "error": {
            "code": "E301",
            "message": "Timed out waiting for app to start (180s)",
          },
          "suggestions": [
            "The app may still be compiling. Try again or check flutter logs.",
            "Use scan_and_connect() after the app finishes launching.",
            "For faster startup, use 'flutter run' manually and then connect_app().",
          ],
        };
      } catch (e) {
        // Catch build errors from completeError
        if (e is Map) {
          return e; // Return the error map directly
        }
        // Fallback for other errors
        return {
          "success": false,
          "error": {
            "code": "E303",
            "message": "Launch failed: $e",
          },
        };
      }
    }

    if (name == 'start_bridge_listener') {
      final port = args['port'] as int? ?? bridgeDefaultPort;
      if (_webBridgeListener != null) {
        return {
          "success": true,
          "message": "Bridge listener already running",
          "port": _webBridgeListener!.port,
          "url": "ws://127.0.0.1:${_webBridgeListener!.port}",
          "has_client": _webBridgeListener!.hasClient,
        };
      }
      try {
        await startBridgeListener(port);
        return {
          "success": true,
          "port": port,
          "url": "ws://127.0.0.1:$port",
          "message": "Bridge listener started. Browser SDK can connect to ws://127.0.0.1:$port",
        };
      } catch (e) {
        return {"success": false, "error": "Failed to start bridge listener: $e"};
      }
    }

    if (name == 'stop_bridge_listener') {
      if (_webBridgeListener == null) {
        return {"success": true, "message": "No bridge listener running"};
      }
      await _webBridgeListener!.stop();
      _webBridgeListener = null;
      return {"success": true, "message": "Bridge listener stopped"};
    }

    if (name == 'scan_and_connect') {
      final portStart = args['port_start'] ?? 50000;
      final portEnd = args['port_end'] ?? 50100;
      final sessionId = args['session_id'] as String? ?? _generateSessionId();

      // Auto-fix configuration if project_path is provided
      final projectPath = args['project_path'] as String?;
      if (projectPath != null) {
        try {
          await runSetup(projectPath);
        } catch (e) {
          // Continue even if setup fails
          print('Warning: Auto-setup failed: $e');
        }
      }

      // Check web bridge listener first
      if (_webBridgeListener != null && _webBridgeListener!.hasClient) {
        final existing = _sessions.values
            .where((s) => s.deviceId == 'web' && s.port == _webBridgeListener!.port);
        if (existing.isNotEmpty) {
          _activeSessionId = existing.first.id;
          return {
            "success": true,
            "connected": "ws://127.0.0.1:${_webBridgeListener!.port}",
            "framework": "web",
            "session_id": existing.first.id,
            "active_session": true,
            "source": "bridge_listener",
          };
        }
        final driver = WebBridgeDriver(_webBridgeListener!);
        await driver.connect();
        _clients[sessionId] = driver;
        _sessions[sessionId] = SessionInfo(
          id: sessionId,
          name: args['name'] as String? ?? 'Web app (bridge listener)',
          projectPath: args['project_path'] as String? ?? 'web',
          deviceId: 'web',
          port: _webBridgeListener!.port!,
          vmServiceUri: 'ws://127.0.0.1:${_webBridgeListener!.port}',
        );
        _activeSessionId = sessionId;
        return {
          "success": true,
          "connected": "ws://127.0.0.1:${_webBridgeListener!.port}",
          "framework": "web",
          "session_id": sessionId,
          "active_session": true,
          "source": "bridge_listener",
        };
      }

      // Try bridge discovery first (cross-framework)
      final bridgeApps = await BridgeDiscovery.discoverAll();
      if (bridgeApps.isNotEmpty) {
        final bridgeApp = bridgeApps.first;

        // Disconnect old client for this session if exists
        if (_clients.containsKey(sessionId)) {
          await _clients[sessionId]!.disconnect();
        }

        var driver = BridgeDriver.fromInfo(bridgeApp);
        try {
          await driver.connect();
        } catch (_) {
          // Some frameworks (Tauri) use port+1 for WebSocket
          final altUri = 'ws://127.0.0.1:${bridgeApp.port + 1}';
          final altInfo = BridgeServiceInfo(
            framework: bridgeApp.framework,
            appName: bridgeApp.appName,
            platform: bridgeApp.platform,
            capabilities: bridgeApp.capabilities,
            sdkVersion: bridgeApp.sdkVersion,
            port: bridgeApp.port + 1,
            wsUri: altUri,
          );
          driver = BridgeDriver.fromInfo(altInfo);
          await driver.connect();
        }

        _clients[sessionId] = driver;
        _sessions[sessionId] = SessionInfo(
          id: sessionId,
          name:
              args['name'] as String? ?? '${bridgeApp.framework} app (bridge)',
          projectPath: args['project_path'] as String? ?? 'unknown',
          deviceId: bridgeApp.platform,
          port: bridgeApp.port,
          vmServiceUri: bridgeApp.wsUri,
        );
        _activeSessionId = sessionId;

        return {
          "success": true,
          "connected": bridgeApp.wsUri,
          "framework": bridgeApp.framework,
          "session_id": sessionId,
          "active_session": true,
          "bridge_apps": bridgeApps.map((a) => a.toJson()).toList(),
        };
      }

      // Fall back to VM Service discovery (Flutter)
      final vmServices = await _scanVmServices(portStart, portEnd);
      if (vmServices.isEmpty) {
        return {
          "success": false,
          "message":
              "No running apps found (checked bridge ports and VM Service ports)"
        };
      }

      // Connect to the first one
      final uri = vmServices.first;

      // Disconnect old client for this session if exists
      if (_clients.containsKey(sessionId)) {
        await _clients[sessionId]!.disconnect();
      }

      final client = FlutterSkillClient(uri);
      await client.connect();

      // Store client and session info
      _clients[sessionId] = client;
      _sessions[sessionId] = SessionInfo(
        id: sessionId,
        name: args['name'] as String? ??
            'Scanned connection ${_sessions.length + 1}',
        projectPath: args['project_path'] as String? ?? 'unknown',
        deviceId: args['device_id'] as String? ?? 'unknown',
        port: int.tryParse(uri.split(':').last.split('/').first) ?? 0,
        vmServiceUri: uri,
      );

      // Always switch to the newly connected session
      _activeSessionId = sessionId;

      return {
        "success": true,
        "connected": uri,
        "framework": "Flutter",
        "session_id": sessionId,
        "active_session": true,
        "available": vmServices
      };
    }

    if (name == 'list_running_apps') {
      final portStart = args['port_start'] ?? 50000;
      final portEnd = args['port_end'] ?? 50100;

      final vmServices = await _scanVmServices(portStart, portEnd);
      return {"apps": vmServices, "count": vmServices.length};
    }

    if (name == 'stop_app') {
      final sessionId = args['session_id'] as String? ?? _activeSessionId;

      if (sessionId != null && _clients.containsKey(sessionId)) {
        await _clients[sessionId]!.disconnect();
        _clients.remove(sessionId);
        _sessions.remove(sessionId);

        // Update active session
        if (_activeSessionId == sessionId) {
          _activeSessionId =
              _sessions.keys.isNotEmpty ? _sessions.keys.first : null;
        }
      }

      if (_flutterProcess != null) {
        _flutterProcess!.kill();
        _flutterProcess = null;
      }

      return {
        "success": true,
        "message": "App stopped",
        "session_id": sessionId,
        "active_session_id": _activeSessionId,
      };
    }

    if (name == 'disconnect') {
      final sessionId = args['session_id'] as String? ?? _activeSessionId;

      if (sessionId != null && _clients.containsKey(sessionId)) {
        final client = _clients[sessionId]!;

        // Clean up CDP driver reference
        if (client is CdpDriver && _cdpDriver == client) {
          _cdpDriver = null;
        }

        await client.disconnect();
        _clients.remove(sessionId);
        _sessions.remove(sessionId);

        // Update active session
        if (_activeSessionId == sessionId) {
          _activeSessionId =
              _sessions.keys.isNotEmpty ? _sessions.keys.first : null;
        }

        return {
          "success": true,
          "message": "Disconnected from session $sessionId",
          "active_session_id": _activeSessionId,
        };
      }

      return {
        "success": false,
        "error": {"message": "No active session or session not found"},
      };
    }

    if (name == 'get_connection_status') {
      final sessionId = args['session_id'] as String? ?? _activeSessionId;

      if (sessionId != null && _clients.containsKey(sessionId)) {
        final client = _clients[sessionId]!;
        final session = _sessions[sessionId];

        return {
          "connected": client.isConnected,
          "framework": client.frameworkName,
          "mode": client is CdpDriver ? "cdp" : (client is BridgeDriver ? "bridge" : "flutter"),
          "session_id": sessionId,
          "uri": client is FlutterSkillClient ? client.vmServiceUri : null,
          "session_info": session?.toJson(),
          "launched_app": _flutterProcess != null,
        };
      }

      // No active session - try to find running apps
      final vmServices = await _scanVmServices(50000, 50100);
      return {
        "connected": false,
        "session_id": null,
        "available_sessions": _sessions.length,
        "launched_app": _flutterProcess != null,
        "available_apps": vmServices,
        "suggestion": vmServices.isNotEmpty
            ? "Found ${vmServices.length} running app(s). Use scan_and_connect() to auto-connect."
            : "No running apps found. Use launch_app() to start one.",
      };
    }


    return null; // Not handled by this group
  }
}
