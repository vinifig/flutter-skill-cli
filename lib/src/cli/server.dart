import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import '../flutter_skill_client.dart';
import 'setup.dart';

const String _currentVersion = '0.2.14';

Future<void> runServer(List<String> args) async {
  // Check for updates in background
  _checkForUpdates();

  final server = FlutterMcpServer();
  await server.run();
}

/// Check pub.dev for newer version
Future<void> _checkForUpdates() async {
  try {
    final response = await http.get(
      Uri.parse('https://pub.dev/api/packages/flutter_skill'),
    ).timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final latestVersion = data['latest']?['version'] as String?;

      if (latestVersion != null && _isNewerVersion(latestVersion, _currentVersion)) {
        stderr.writeln('');
        stderr.writeln('╔══════════════════════════════════════════════════════════╗');
        stderr.writeln('║  flutter-skill v$latestVersion available (current: v$_currentVersion)');
        stderr.writeln('║                                                          ║');
        stderr.writeln('║  Update with:                                            ║');
        stderr.writeln('║    dart pub global activate flutter_skill                ║');
        stderr.writeln('║  Or:                                                     ║');
        stderr.writeln('║    npm update -g flutter-skill-mcp                       ║');
        stderr.writeln('╚══════════════════════════════════════════════════════════╝');
        stderr.writeln('');
      }
    }
  } catch (e) {
    // Ignore update check errors
  }
}

/// Compare semantic versions
bool _isNewerVersion(String latest, String current) {
  final latestParts = latest.split('.').map(int.tryParse).toList();
  final currentParts = current.split('.').map(int.tryParse).toList();

  for (int i = 0; i < 3; i++) {
    final l = i < latestParts.length ? (latestParts[i] ?? 0) : 0;
    final c = i < currentParts.length ? (currentParts[i] ?? 0) : 0;
    if (l > c) return true;
    if (l < c) return false;
  }
  return false;
}

class FlutterMcpServer {
  FlutterSkillClient? _client;
  Process? _flutterProcess;

  Future<void> run() async {
    stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
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
          "capabilities": {"tools": {}, "resources": {}},
          "protocolVersion": "2024-11-05",
          "serverInfo": {"name": "flutter-skill-mcp", "version": _currentVersion},
        });
      } else if (method == 'notifications/initialized') {
        // No op
      } else if (method == 'tools/list') {
        _sendResult(id, {"tools": _getToolsList()});
      } else if (method == 'tools/call') {
        final name = params['name'];
        final args = params['arguments'] as Map<String, dynamic>? ?? {};
        final result = await _executeTool(name, args);
        _sendResult(id, {
          "content": [
            {"type": "text", "text": jsonEncode(result)},
          ],
        });
      }
    } catch (e) {
      if (id != null) {
        _sendError(id, -32603, "Internal error: $e");
      }
    }
  }

  List<Map<String, dynamic>> _getToolsList() {
    return [
      // Connection
      {
        "name": "connect_app",
        "description": "Connect to a running Flutter App VM Service",
        "inputSchema": {
          "type": "object",
          "properties": {
            "uri": {"type": "string", "description": "WebSocket URI (ws://...)"},
          },
          "required": ["uri"],
        },
      },
      {
        "name": "launch_app",
        "description": "Launch a Flutter app and auto-connect",
        "inputSchema": {
          "type": "object",
          "properties": {
            "project_path": {"type": "string", "description": "Path to Flutter project"},
            "device_id": {"type": "string", "description": "Target device"},
            "dart_defines": {"type": "array", "items": {"type": "string"}, "description": "Dart defines (e.g. ['ENV=staging', 'DEBUG=true'])"},
            "extra_args": {"type": "array", "items": {"type": "string"}, "description": "Additional flutter run arguments"},
            "flavor": {"type": "string", "description": "Build flavor"},
            "target": {"type": "string", "description": "Target file (e.g. lib/main_staging.dart)"},
          },
        },
      },
      {
        "name": "scan_and_connect",
        "description": "Scan for running Flutter apps and auto-connect to the first one found",
        "inputSchema": {
          "type": "object",
          "properties": {
            "port_start": {"type": "integer", "description": "Start of port range (default: 50000)"},
            "port_end": {"type": "integer", "description": "End of port range (default: 50100)"},
          },
        },
      },
      {
        "name": "list_running_apps",
        "description": "List all running Flutter apps (VM Services) on the system",
        "inputSchema": {
          "type": "object",
          "properties": {
            "port_start": {"type": "integer", "description": "Start of port range (default: 50000)"},
            "port_end": {"type": "integer", "description": "End of port range (default: 50100)"},
          },
        },
      },
      {
        "name": "stop_app",
        "description": "Stop the currently connected/launched Flutter app",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "disconnect",
        "description": "Disconnect from the current Flutter app (without stopping it)",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "get_connection_status",
        "description": "Get current connection status and app info",
        "inputSchema": {"type": "object", "properties": {}},
      },

      // Basic Inspection
      {
        "name": "inspect",
        "description": "Get interactive elements (buttons, text fields, etc.)",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "get_widget_tree",
        "description": "Get the full widget tree structure",
        "inputSchema": {
          "type": "object",
          "properties": {
            "max_depth": {"type": "integer", "description": "Maximum tree depth (default: 10)"},
          },
        },
      },
      {
        "name": "get_widget_properties",
        "description": "Get properties of a widget by key",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
          },
          "required": ["key"],
        },
      },
      {
        "name": "get_text_content",
        "description": "Get all text content on the screen",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "find_by_type",
        "description": "Find widgets by type name",
        "inputSchema": {
          "type": "object",
          "properties": {
            "type": {"type": "string", "description": "Widget type name to search"},
          },
          "required": ["type"],
        },
      },

      // Basic Actions
      {
        "name": "tap",
        "description": "Tap an element",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
          },
        },
      },
      {
        "name": "enter_text",
        "description": "Enter text into an input field",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "TextField key"},
            "text": {"type": "string", "description": "Text to enter"},
          },
          "required": ["key", "text"],
        },
      },
      {
        "name": "scroll_to",
        "description": "Scroll to make an element visible",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
          },
        },
      },

      // Advanced Actions
      {
        "name": "long_press",
        "description": "Long press on an element",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
            "duration": {"type": "integer", "description": "Duration in ms (default: 500)"},
          },
        },
      },
      {
        "name": "double_tap",
        "description": "Double tap on an element",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
          },
        },
      },
      {
        "name": "swipe",
        "description": "Perform a swipe gesture",
        "inputSchema": {
          "type": "object",
          "properties": {
            "direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
            "distance": {"type": "number", "description": "Swipe distance in pixels (default: 300)"},
            "key": {"type": "string", "description": "Start from element (optional)"},
          },
          "required": ["direction"],
        },
      },
      {
        "name": "drag",
        "description": "Drag from one element to another",
        "inputSchema": {
          "type": "object",
          "properties": {
            "from_key": {"type": "string", "description": "Source element key"},
            "to_key": {"type": "string", "description": "Target element key"},
          },
          "required": ["from_key", "to_key"],
        },
      },

      // State & Validation
      {
        "name": "get_text_value",
        "description": "Get current value of a text field",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "TextField key"},
          },
          "required": ["key"],
        },
      },
      {
        "name": "get_checkbox_state",
        "description": "Get state of a checkbox or switch",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Checkbox/Switch key"},
          },
          "required": ["key"],
        },
      },
      {
        "name": "get_slider_value",
        "description": "Get current value of a slider",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Slider key"},
          },
          "required": ["key"],
        },
      },
      {
        "name": "wait_for_element",
        "description": "Wait for an element to appear",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
            "timeout": {"type": "integer", "description": "Timeout in ms (default: 5000)"},
          },
        },
      },
      {
        "name": "wait_for_gone",
        "description": "Wait for an element to disappear",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
            "timeout": {"type": "integer", "description": "Timeout in ms (default: 5000)"},
          },
        },
      },

      // Screenshot
      {
        "name": "screenshot",
        "description": "Take a screenshot of the app",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "screenshot_element",
        "description": "Take a screenshot of a specific element",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Element key"},
          },
          "required": ["key"],
        },
      },

      // Navigation
      {
        "name": "get_current_route",
        "description": "Get the current route name",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "go_back",
        "description": "Navigate back",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "get_navigation_stack",
        "description": "Get the navigation stack",
        "inputSchema": {"type": "object", "properties": {}},
      },

      // Debug & Logs
      {
        "name": "get_logs",
        "description": "Get application logs",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "get_errors",
        "description": "Get application errors",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "clear_logs",
        "description": "Clear logs and errors",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "get_performance",
        "description": "Get performance metrics",
        "inputSchema": {"type": "object", "properties": {}},
      },

      // Utilities
      {
        "name": "hot_reload",
        "description": "Trigger hot reload (fast, keeps app state)",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "hot_restart",
        "description": "Trigger hot restart (slower, resets app state)",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "pub_search",
        "description": "Search Flutter packages on pub.dev",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": {"type": "string", "description": "Search query"},
          },
          "required": ["query"],
        },
      },

      // === NEW: Batch Operations ===
      {
        "name": "execute_batch",
        "description": "Execute multiple actions in sequence. Reduces round-trip latency for complex test flows.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "actions": {
              "type": "array",
              "description": "List of actions to execute",
              "items": {
                "type": "object",
                "properties": {
                  "action": {"type": "string", "description": "Action name (tap, enter_text, swipe, wait, screenshot, assert_visible, assert_text)"},
                  "key": {"type": "string"},
                  "text": {"type": "string"},
                  "value": {"type": "string"},
                  "direction": {"type": "string"},
                  "duration": {"type": "integer"},
                  "expected": {"type": "string"},
                },
                "required": ["action"],
              },
            },
            "stop_on_failure": {"type": "boolean", "description": "Stop execution on first failure (default: true)"},
          },
          "required": ["actions"],
        },
      },

      // === NEW: Coordinate-based Actions ===
      {
        "name": "tap_at",
        "description": "Tap at specific screen coordinates",
        "inputSchema": {
          "type": "object",
          "properties": {
            "x": {"type": "number", "description": "X coordinate"},
            "y": {"type": "number", "description": "Y coordinate"},
          },
          "required": ["x", "y"],
        },
      },
      {
        "name": "long_press_at",
        "description": "Long press at specific screen coordinates",
        "inputSchema": {
          "type": "object",
          "properties": {
            "x": {"type": "number", "description": "X coordinate"},
            "y": {"type": "number", "description": "Y coordinate"},
            "duration": {"type": "integer", "description": "Duration in ms (default: 500)"},
          },
          "required": ["x", "y"],
        },
      },
      {
        "name": "swipe_coordinates",
        "description": "Swipe from one coordinate to another",
        "inputSchema": {
          "type": "object",
          "properties": {
            "start_x": {"type": "number", "description": "Start X coordinate"},
            "start_y": {"type": "number", "description": "Start Y coordinate"},
            "end_x": {"type": "number", "description": "End X coordinate"},
            "end_y": {"type": "number", "description": "End Y coordinate"},
            "duration": {"type": "integer", "description": "Duration in ms (default: 300)"},
          },
          "required": ["start_x", "start_y", "end_x", "end_y"],
        },
      },

      // === NEW: Smart Scroll ===
      {
        "name": "scroll_until_visible",
        "description": "Scroll in a direction until target element becomes visible",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Target element key"},
            "text": {"type": "string", "description": "Target element text"},
            "direction": {"type": "string", "enum": ["up", "down", "left", "right"], "description": "Scroll direction (default: down)"},
            "max_scrolls": {"type": "integer", "description": "Maximum scroll attempts (default: 10)"},
            "scrollable_key": {"type": "string", "description": "Key of the scrollable container (optional)"},
          },
        },
      },

      // === NEW: Assertions ===
      {
        "name": "assert_visible",
        "description": "Assert that an element is visible on screen",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Element key"},
            "text": {"type": "string", "description": "Element text"},
            "timeout": {"type": "integer", "description": "Wait timeout in ms (default: 5000)"},
          },
        },
      },
      {
        "name": "assert_not_visible",
        "description": "Assert that an element is NOT visible on screen",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Element key"},
            "text": {"type": "string", "description": "Element text"},
            "timeout": {"type": "integer", "description": "Wait timeout in ms (default: 5000)"},
          },
        },
      },
      {
        "name": "assert_text",
        "description": "Assert that an element contains specific text",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Element key"},
            "expected": {"type": "string", "description": "Expected text content"},
            "contains": {"type": "boolean", "description": "Use contains instead of equals (default: false)"},
          },
          "required": ["key", "expected"],
        },
      },
      {
        "name": "assert_element_count",
        "description": "Assert the count of elements matching criteria",
        "inputSchema": {
          "type": "object",
          "properties": {
            "type": {"type": "string", "description": "Widget type to count"},
            "text": {"type": "string", "description": "Text to match"},
            "expected_count": {"type": "integer", "description": "Expected count"},
            "min_count": {"type": "integer", "description": "Minimum count (alternative to exact)"},
            "max_count": {"type": "integer", "description": "Maximum count (alternative to exact)"},
          },
        },
      },

      // === NEW: Page State ===
      {
        "name": "get_page_state",
        "description": "Get complete page state snapshot (route, scroll position, focused element, keyboard, loading indicators)",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "get_interactable_elements",
        "description": "Get all interactable elements on current screen with suggested actions",
        "inputSchema": {
          "type": "object",
          "properties": {
            "include_positions": {"type": "boolean", "description": "Include x/y positions (default: true)"},
          },
        },
      },

      // === NEW: Performance & Memory ===
      {
        "name": "get_frame_stats",
        "description": "Get frame rendering statistics (FPS, jank, build/raster times)",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "get_memory_stats",
        "description": "Get memory usage statistics (heap, external)",
        "inputSchema": {"type": "object", "properties": {}},
      },
    ];
  }

  Future<dynamic> _executeTool(String name, Map<String, dynamic> args) async {
    // Connection tools
    if (name == 'connect_app') {
      final uri = args['uri'] as String;
      if (_client != null) await _client!.disconnect();
      _client = FlutterSkillClient(uri);
      await _client!.connect();
      return "Connected to $uri";
    }

    if (name == 'launch_app') {
      final projectPath = args['project_path'] ?? '.';
      final deviceId = args['device_id'];
      final dartDefines = args['dart_defines'] as List<dynamic>?;
      final extraArgs = args['extra_args'] as List<dynamic>?;
      final flavor = args['flavor'];
      final target = args['target'];

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

      _flutterProcess = await Process.start('flutter', processArgs, workingDirectory: projectPath);

      final completer = Completer<String>();

      _flutterProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.contains('ws://')) {
          final uriRegex = RegExp(r'ws://[a-zA-Z0-9.:/-]+');
          final match = uriRegex.firstMatch(line);
          if (match != null) {
            final uri = match.group(0)!;
            _client?.disconnect();
            _client = FlutterSkillClient(uri);
            _client!.connect().then((_) {
              if (!completer.isCompleted) completer.complete("Launched and connected to $uri");
            }).catchError((e) {
              if (!completer.isCompleted) completer.completeError("Found URI but failed to connect: $e");
            });
          }
        }
      });

      _flutterProcess!.exitCode.then((code) {
        if (!completer.isCompleted) {
          completer.completeError("Flutter app exited with code $code");
        }
        _flutterProcess = null;
      });

      return completer.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () => "Timed out waiting for app to start",
      );
    }

    if (name == 'scan_and_connect') {
      final portStart = args['port_start'] ?? 50000;
      final portEnd = args['port_end'] ?? 50100;

      final vmServices = await _scanVmServices(portStart, portEnd);
      if (vmServices.isEmpty) {
        return {"success": false, "message": "No running Flutter apps found"};
      }

      // Connect to the first one
      final uri = vmServices.first;
      if (_client != null) await _client!.disconnect();
      _client = FlutterSkillClient(uri);
      await _client!.connect();
      return {"success": true, "connected": uri, "available": vmServices};
    }

    if (name == 'list_running_apps') {
      final portStart = args['port_start'] ?? 50000;
      final portEnd = args['port_end'] ?? 50100;

      final vmServices = await _scanVmServices(portStart, portEnd);
      return {"apps": vmServices, "count": vmServices.length};
    }

    if (name == 'stop_app') {
      if (_flutterProcess != null) {
        _flutterProcess!.kill();
        _flutterProcess = null;
      }
      if (_client != null) {
        await _client!.disconnect();
        _client = null;
      }
      return {"success": true, "message": "App stopped"};
    }

    if (name == 'disconnect') {
      if (_client != null) {
        await _client!.disconnect();
        _client = null;
      }
      return {"success": true, "message": "Disconnected"};
    }

    if (name == 'get_connection_status') {
      final isConnected = _client != null && _client!.isConnected;
      final hasLaunchedApp = _flutterProcess != null;

      if (!isConnected) {
        // Try to find running apps to provide helpful suggestions
        final vmServices = await _scanVmServices(50000, 50100);
        return {
          "connected": false,
          "launched_app": hasLaunchedApp,
          "available_apps": vmServices,
          "suggestion": vmServices.isNotEmpty
              ? "Found ${vmServices.length} running app(s). Use scan_and_connect() to auto-connect."
              : "No running apps found. Use launch_app() to start one.",
        };
      }

      return {
        "connected": true,
        "uri": _client!.vmServiceUri,
        "launched_app": hasLaunchedApp,
      };
    }

    if (name == 'pub_search') {
      final query = args['query'];
      final url = Uri.parse('https://pub.dev/api/search?q=$query');
      final response = await http.get(url);
      if (response.statusCode != 200) throw Exception("Pub search failed");
      final json = jsonDecode(response.body);
      return json['packages'];
    }

    if (name == 'hot_reload') {
      _requireConnection();
      await _client!.hotReload();
      return "Hot reload triggered";
    }

    if (name == 'hot_restart') {
      _requireConnection();
      await _client!.hotRestart();
      return "Hot restart triggered";
    }

    // Require connection for all other tools
    _requireConnection();

    switch (name) {
      // Inspection
      case 'inspect':
        return await _client!.getInteractiveElements();
      case 'get_widget_tree':
        final maxDepth = args['max_depth'] ?? 10;
        return await _client!.getWidgetTree(maxDepth: maxDepth);
      case 'get_widget_properties':
        return await _client!.getWidgetProperties(args['key']);
      case 'get_text_content':
        return await _client!.getTextContent();
      case 'find_by_type':
        return await _client!.findByType(args['type']);

      // Basic Actions
      case 'tap':
        await _client!.tap(key: args['key'], text: args['text']);
        return "Tapped";
      case 'enter_text':
        await _client!.enterText(args['key'], args['text']);
        return "Entered text";
      case 'scroll_to':
        await _client!.scrollTo(key: args['key'], text: args['text']);
        return "Scrolled";

      // Advanced Actions
      case 'long_press':
        final duration = args['duration'] ?? 500;
        final success = await _client!.longPress(key: args['key'], text: args['text'], duration: duration);
        return success ? "Long pressed" : "Long press failed";
      case 'double_tap':
        final success = await _client!.doubleTap(key: args['key'], text: args['text']);
        return success ? "Double tapped" : "Double tap failed";
      case 'swipe':
        final distance = (args['distance'] ?? 300).toDouble();
        final success = await _client!.swipe(direction: args['direction'], distance: distance, key: args['key']);
        return success ? "Swiped ${args['direction']}" : "Swipe failed";
      case 'drag':
        final success = await _client!.drag(fromKey: args['from_key'], toKey: args['to_key']);
        return success ? "Dragged" : "Drag failed";

      // State & Validation
      case 'get_text_value':
        return await _client!.getTextValue(args['key']);
      case 'get_checkbox_state':
        return await _client!.getCheckboxState(args['key']);
      case 'get_slider_value':
        return await _client!.getSliderValue(args['key']);
      case 'wait_for_element':
        final timeout = args['timeout'] ?? 5000;
        final found = await _client!.waitForElement(key: args['key'], text: args['text'], timeout: timeout);
        return {"found": found};
      case 'wait_for_gone':
        final timeout = args['timeout'] ?? 5000;
        final gone = await _client!.waitForGone(key: args['key'], text: args['text'], timeout: timeout);
        return {"gone": gone};

      // Screenshot
      case 'screenshot':
        final image = await _client!.takeScreenshot();
        return {"image": image};
      case 'screenshot_element':
        final image = await _client!.takeElementScreenshot(args['key']);
        return {"image": image};

      // Navigation
      case 'get_current_route':
        return await _client!.getCurrentRoute();
      case 'go_back':
        final success = await _client!.goBack();
        return success ? "Navigated back" : "Cannot go back";
      case 'get_navigation_stack':
        return await _client!.getNavigationStack();

      // Debug & Logs
      case 'get_logs':
        return await _client!.getLogs();
      case 'get_errors':
        return await _client!.getErrors();
      case 'clear_logs':
        await _client!.clearLogs();
        return "Logs cleared";
      case 'get_performance':
        return await _client!.getPerformance();

      // === NEW: Batch Operations ===
      case 'execute_batch':
        return await _executeBatch(args);

      // === NEW: Coordinate-based Actions ===
      case 'tap_at':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        await _client!.tapAt(x, y);
        return {"success": true, "action": "tap_at", "x": x, "y": y};

      case 'long_press_at':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final duration = args['duration'] ?? 500;
        await _client!.longPressAt(x, y, duration: duration);
        return {"success": true, "action": "long_press_at", "x": x, "y": y};

      case 'swipe_coordinates':
        final startX = (args['start_x'] as num).toDouble();
        final startY = (args['start_y'] as num).toDouble();
        final endX = (args['end_x'] as num).toDouble();
        final endY = (args['end_y'] as num).toDouble();
        final duration = args['duration'] ?? 300;
        await _client!.swipeCoordinates(startX, startY, endX, endY, duration: duration);
        return {"success": true, "action": "swipe_coordinates"};

      // === NEW: Smart Scroll ===
      case 'scroll_until_visible':
        return await _scrollUntilVisible(args);

      // === NEW: Assertions ===
      case 'assert_visible':
        return await _assertVisible(args, shouldBeVisible: true);

      case 'assert_not_visible':
        return await _assertVisible(args, shouldBeVisible: false);

      case 'assert_text':
        return await _assertText(args);

      case 'assert_element_count':
        return await _assertElementCount(args);

      // === NEW: Page State ===
      case 'get_page_state':
        return await _getPageState();

      case 'get_interactable_elements':
        final includePositions = args['include_positions'] ?? true;
        return await _client!.getInteractiveElements(includePositions: includePositions);

      // === NEW: Performance & Memory ===
      case 'get_frame_stats':
        return await _client!.getFrameStats();

      case 'get_memory_stats':
        return await _client!.getMemoryStats();

      default:
        throw Exception("Unknown tool: $name");
    }
  }

  /// Execute a batch of actions in sequence
  Future<Map<String, dynamic>> _executeBatch(Map<String, dynamic> args) async {
    final actions = args['actions'] as List<dynamic>;
    final stopOnFailure = args['stop_on_failure'] ?? true;

    final results = <Map<String, dynamic>>[];
    var allSuccess = true;

    for (var i = 0; i < actions.length; i++) {
      final action = actions[i] as Map<String, dynamic>;
      final actionName = action['action'] as String;
      final startTime = DateTime.now();

      try {
        dynamic result;

        switch (actionName) {
          case 'tap':
            await _client!.tap(key: action['key'], text: action['text']);
            result = "Tapped";
            break;

          case 'enter_text':
            await _client!.enterText(action['key'], action['text'] ?? action['value']);
            result = "Entered text";
            break;

          case 'swipe':
            final distance = (action['distance'] ?? 300).toDouble();
            await _client!.swipe(
              direction: action['direction'] ?? 'down',
              distance: distance,
              key: action['key'],
            );
            result = "Swiped";
            break;

          case 'wait':
            final duration = action['duration'] ?? 500;
            await Future.delayed(Duration(milliseconds: duration));
            result = "Waited ${duration}ms";
            break;

          case 'screenshot':
            final image = await _client!.takeScreenshot();
            result = {"image": image};
            break;

          case 'assert_visible':
            final timeout = action['timeout'] ?? 5000;
            final found = await _client!.waitForElement(
              key: action['key'],
              text: action['text'],
              timeout: timeout,
            );
            if (!found) throw Exception("Element not visible");
            result = "Visible";
            break;

          case 'assert_text':
            final actual = await _client!.getTextValue(action['key']);
            final expected = action['expected'];
            if (actual != expected) {
              throw Exception("Text mismatch: expected '$expected', got '$actual'");
            }
            result = "Text matches";
            break;

          case 'long_press':
            final duration = action['duration'] ?? 500;
            await _client!.longPress(key: action['key'], text: action['text'], duration: duration);
            result = "Long pressed";
            break;

          case 'double_tap':
            await _client!.doubleTap(key: action['key'], text: action['text']);
            result = "Double tapped";
            break;

          case 'scroll_to':
            await _client!.scrollTo(key: action['key'], text: action['text']);
            result = "Scrolled";
            break;

          default:
            throw Exception("Unknown batch action: $actionName");
        }

        final duration = DateTime.now().difference(startTime).inMilliseconds;
        results.add({
          "step": i + 1,
          "action": actionName,
          "success": true,
          "duration_ms": duration,
          "result": result,
        });

      } catch (e) {
        allSuccess = false;
        final duration = DateTime.now().difference(startTime).inMilliseconds;
        results.add({
          "step": i + 1,
          "action": actionName,
          "success": false,
          "duration_ms": duration,
          "error": e.toString(),
        });

        if (stopOnFailure) break;
      }
    }

    return {
      "success": allSuccess,
      "total_steps": actions.length,
      "completed_steps": results.length,
      "results": results,
    };
  }

  /// Scroll until element becomes visible
  Future<Map<String, dynamic>> _scrollUntilVisible(Map<String, dynamic> args) async {
    final key = args['key'] as String?;
    final text = args['text'] as String?;
    final direction = args['direction'] ?? 'down';
    final maxScrolls = args['max_scrolls'] ?? 10;
    final scrollableKey = args['scrollable_key'] as String?;

    for (var i = 0; i < maxScrolls; i++) {
      // Check if element is visible
      final found = await _client!.waitForElement(
        key: key,
        text: text,
        timeout: 500,
      );

      if (found) {
        return {
          "success": true,
          "found": true,
          "scrolls_needed": i,
        };
      }

      // Scroll
      await _client!.swipe(
        direction: direction,
        distance: 300,
        key: scrollableKey,
      );

      // Wait for scroll animation
      await Future.delayed(const Duration(milliseconds: 300));
    }

    return {
      "success": false,
      "found": false,
      "scrolls_attempted": maxScrolls,
      "message": "Element not found after $maxScrolls scrolls",
    };
  }

  /// Assert element visibility
  Future<Map<String, dynamic>> _assertVisible(Map<String, dynamic> args, {required bool shouldBeVisible}) async {
    final key = args['key'] as String?;
    final text = args['text'] as String?;
    final timeout = args['timeout'] ?? 5000;

    if (shouldBeVisible) {
      final found = await _client!.waitForElement(key: key, text: text, timeout: timeout);
      return {
        "success": found,
        "assertion": "visible",
        "element": key ?? text,
        "message": found ? "Element is visible" : "Element not found within ${timeout}ms",
      };
    } else {
      final gone = await _client!.waitForGone(key: key, text: text, timeout: timeout);
      return {
        "success": gone,
        "assertion": "not_visible",
        "element": key ?? text,
        "message": gone ? "Element is not visible" : "Element still visible after ${timeout}ms",
      };
    }
  }

  /// Assert text content
  Future<Map<String, dynamic>> _assertText(Map<String, dynamic> args) async {
    final key = args['key'] as String;
    final expected = args['expected'] as String;
    final useContains = args['contains'] ?? false;

    final actual = await _client!.getTextValue(key);

    bool matches;
    if (useContains) {
      matches = actual?.contains(expected) ?? false;
    } else {
      matches = actual == expected;
    }

    return {
      "success": matches,
      "assertion": useContains ? "text_contains" : "text_equals",
      "element": key,
      "expected": expected,
      "actual": actual,
      "message": matches
          ? "Text assertion passed"
          : "Text mismatch: expected ${useContains ? 'to contain' : ''} '$expected', got '$actual'",
    };
  }

  /// Assert element count
  Future<Map<String, dynamic>> _assertElementCount(Map<String, dynamic> args) async {
    final type = args['type'] as String?;
    final text = args['text'] as String?;
    final expectedCount = args['expected_count'] as int?;
    final minCount = args['min_count'] as int?;
    final maxCount = args['max_count'] as int?;

    int count = 0;

    if (type != null) {
      final elements = await _client!.findByType(type);
      count = elements.length;
    } else if (text != null) {
      final allText = await _client!.getTextContent();
      count = RegExp(RegExp.escape(text)).allMatches(allText.toString()).length;
    }

    bool success = true;
    String message = "";

    if (expectedCount != null) {
      success = count == expectedCount;
      message = success
          ? "Count matches: $count"
          : "Count mismatch: expected $expectedCount, got $count";
    } else {
      if (minCount != null && count < minCount) {
        success = false;
        message = "Count $count is less than minimum $minCount";
      }
      if (maxCount != null && count > maxCount) {
        success = false;
        message = "Count $count is greater than maximum $maxCount";
      }
      if (success) {
        message = "Count $count is within expected range";
      }
    }

    return {
      "success": success,
      "assertion": "element_count",
      "count": count,
      "message": message,
    };
  }

  /// Get complete page state snapshot
  Future<Map<String, dynamic>> _getPageState() async {
    final route = await _client!.getCurrentRoute();
    final interactables = await _client!.getInteractiveElements();
    final textContent = await _client!.getTextContent();

    return {
      "route": route,
      "interactive_elements_count": (interactables as List?)?.length ?? 0,
      "text_content_preview": textContent.toString().substring(0, textContent.toString().length.clamp(0, 500)),
      "timestamp": DateTime.now().toIso8601String(),
    };
  }

  void _requireConnection() {
    if (_client == null || !_client!.isConnected) {
      throw Exception('''Not connected to Flutter app.

Solutions:
1. If app is already running: call scan_and_connect() to auto-detect and connect
2. To start a new app: call launch_app(project_path: "/path/to/project")
3. If you have the VM Service URI: call connect_app(uri: "ws://...")

Tip: Use get_connection_status() to see available running apps.''');
    }
  }

  /// Scan for VM Services on local ports
  Future<List<String>> _scanVmServices(int portStart, int portEnd) async {
    final vmServices = <String>[];
    final futures = <Future>[];

    for (var port = portStart; port <= portEnd; port++) {
      futures.add(_checkVmServicePort(port).then((uri) {
        if (uri != null) vmServices.add(uri);
      }));
    }

    await Future.wait(futures);
    return vmServices;
  }

  /// Check if a specific port has a VM Service
  Future<String?> _checkVmServicePort(int port) async {
    try {
      final socket = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 200));
      await socket.close();

      // Try to get VM Service info via HTTP
      final response = await http.get(
        Uri.parse('http://127.0.0.1:$port/'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(milliseconds: 500));

      if (response.statusCode == 200) {
        // Extract WebSocket URI from response
        final body = response.body;
        if (body.contains('ws://') || body.contains('Dart VM')) {
          // Construct WebSocket URI
          return 'ws://127.0.0.1:$port/ws';
        }
      }
    } catch (e) {
      // Port not available or not a VM Service
    }
    return null;
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
      "error": {"code": code, "message": message},
    }));
  }
}
