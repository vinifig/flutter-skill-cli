import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'lib/flutter_skill_client.dart';

// Minimal MCP Server implementation over Stdio.
// Does not depend on large mcp packages to keep it lightweight.

void main() async {
  final server = FlutterMcpServer();
  await server.run();
}

class FlutterMcpServer {
  FlutterSkillClient? _client;
  Process? _flutterProcess;

  Future<void> run() async {
    // Read from stdin, line by line (JSON-RPC)
    stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) async {
      if (line.trim().isEmpty) return;
      try {
        final request = jsonDecode(line);
        if (request is Map<String, dynamic>) {
          await _handleRequest(request);
        }
      } catch (e) {
        _sendError(null, -32700, "Parse error: $e");
      }
    });
  }

  Future<void> _handleRequest(Map<String, dynamic> request) async {
    final id = request['id'];
    final method = request['method'];
    final params = request['params'] as Map<String, dynamic>? ?? {};

    try {
      if (method == 'initialize') {
        _sendResult(id, {
          "capabilities": {
            "tools": {},
            "resources": {},
          },
          "protocolVersion": "2024-11-05", // Example version
          "serverInfo": {"name": "flutter-skill-mcp", "version": "1.0.0"}
        });
      } else if (method == 'notifications/initialized') {
        // No op
      } else if (method == 'tools/list') {
        _sendResult(id, {
          "tools": [
            {
              "name": "connect_app",
              "description": "Connect to a running Flutter App VM Service",
              "inputSchema": {
                "type": "object",
                "properties": {
                  "uri": {
                    "type": "string",
                    "description": "WebSocket URI (ws://...)"
                  }
                },
                "required": ["uri"]
              }
            },
            {
              "name": "launch_app",
              "description": "Launch a Flutter app and auto-connect",
              "inputSchema": {
                "type": "object",
                "properties": {
                  "project_path": {
                    "type": "string",
                    "description": "Path to Flutter project (default: current)"
                  },
                  "device_id": {
                    "type": "string",
                    "description": "Destination device (optional)"
                  }
                }
              }
            },
            {
              "name": "inspect",
              "description": "Get the interactive widget tree",
              "inputSchema": {"type": "object", "properties": {}}
            },
            {
              "name": "tap",
              "description": "Tap an interactive element",
              "inputSchema": {
                "type": "object",
                "properties": {
                  "key": {"type": "string"},
                  "text": {"type": "string"}
                }
              }
            },
            {
              "name": "enter_text",
              "description": "Enter text into an element",
              "inputSchema": {
                "type": "object",
                "properties": {
                  "key": {"type": "string"},
                  "text": {"type": "string"}
                },
                "required": ["key", "text"]
              }
            },
            {
              "name": "pub_search",
              "description": "Search for Flutter packages on pub.dev",
              "inputSchema": {
                "type": "object",
                "properties": {
                  "query": {"type": "string"}
                },
                "required": ["query"]
              }
            }
          ]
        });
      } else if (method == 'tools/call') {
        final name = params['name'];
        final args = params['arguments'] as Map<String, dynamic>? ?? {};
        final result = await _executeTool(name, args);
        _sendResult(id, {
          "content": [
            {"type": "text", "text": jsonEncode(result)}
          ]
        });
      } else {
        // Unknown method, or ping
        // Ignore or error
      }
    } catch (e) {
      if (id != null) {
        _sendError(id, -32603, "Internal error: $e");
      }
    }
  }

  Future<dynamic> _executeTool(String name, Map<String, dynamic> args) async {
    if (name == 'connect_app') {
      final uri = args['uri'] as String;
      if (_client != null) {
        await _client!.disconnect();
      }
      _client = FlutterSkillClient(uri);
      await _client!.connect();
      return "Connected to $uri";
    }

    if (name == 'launch_app') {
      final projectPath = args['project_path'] ?? '.';
      final deviceId = args['device_id'];

      if (_flutterProcess != null) {
        _flutterProcess!.kill();
        _flutterProcess = null;
      }

      final processArgs = ['run'];
      if (deviceId != null) {
        processArgs.addAll(['-d', deviceId]);
      }

      // Auto-Setup
      final scriptDir = File(Platform.script.toFilePath()).parent.path;
      final setupScript = '$scriptDir/setup.dart';

      try {
        // Run setup synchronously (await)
        final setupRes =
            await Process.run('dart', ['run', setupScript, projectPath]);
        // We log stderr but don't fail hard, as maybe setup isn't needed or failed but launch might work
        if (setupRes.exitCode != 0) {
          // Log somewhere? mcp doesn't have easy log stream to user unless we send log notification
          // For now, ignore.
        }
      } catch (e) {
        // Ignore
      }

      // We spawn the process
      _flutterProcess = await Process.start(
        'flutter',
        processArgs,
        workingDirectory: projectPath,
      );

      // We need to listen to stdout to find the URI.
      // We return a Future that completes when URI is found?
      // Or we just return "Launching..." and let the agent poll?
      // Better to wait for connection so it's a synchronous "Launch & Connect" action from Agent perspective.

      final completer = Completer<String>();

      _flutterProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        // Find URI
        if (line.contains('ws://')) {
          final uriRegex = RegExp(r'ws://[a-zA-Z0-9.:/-]+');
          final match = uriRegex.firstMatch(line);
          if (match != null) {
            final uri = match.group(0)!;
            // Connect!
            _client?.disconnect(); // Disconnect existing
            _client = FlutterSkillClient(uri);
            _client!.connect().then((_) {
              if (!completer.isCompleted)
                completer.complete("Launched and connected to $uri");
            }).catchError((e) {
              if (!completer.isCompleted)
                completer
                    .completeError("Found URI $uri but failed to connect: $e");
            });
          }
        }
      });

      // Also listen to stderr/exit
      _flutterProcess!.stderr.transform(utf8.decoder).listen((data) {
        // Log?
      });
      _flutterProcess!.exitCode.then((code) {
        if (!completer.isCompleted)
          completer
              .completeError("Flutter app exited prematurely with code $code");
        _flutterProcess = null;
      });

      // Timeout after 60s
      return completer.future.timeout(const Duration(seconds: 60),
          onTimeout: () => "Timed out waiting for app to start");
    }

    if (name == 'pub_search') {
      // Re-implement pub search logic briefly or call script?
      // Let's implement directly for speed
      final query = args['query'];
      final url = Uri.parse('https://pub.dev/api/search?q=$query');
      final response = await http.get(url);
      if (response.statusCode != 200) throw Exception("Pub failed");
      final json = jsonDecode(response.body);
      return json['packages']; // Return raw list for agent
    }

    // App interaction tools require connection
    if (_client == null || !_client!.isConnected) {
      throw Exception("Not connected. Call 'connect_app' first.");
    }

    switch (name) {
      case 'inspect':
        return await _client!.getInteractiveElements();
      case 'tap':
        await _client!.tap(key: args['key'], text: args['text']);
        return "Tapped";
      case 'enter_text':
        await _client!.enterText(args['key'], args['text']);
        return "Entered text";
      default:
        throw Exception("Unknown tool $name");
    }
  }

  void _sendResult(dynamic id, dynamic result) {
    if (id == null) return;
    stdout.writeln(jsonEncode({"jsonrpc": "2.0", "id": id, "result": result}));
  }

  void _sendError(dynamic id, int code, String message) {
    if (id == null) return;
    stdout.writeln(jsonEncode({
      "jsonrpc": "2.0",
      "id": id,
      "error": {"code": code, "message": message}
    }));
  }
}
