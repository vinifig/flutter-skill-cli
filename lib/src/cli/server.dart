import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import '../flutter_skill_client.dart';
import 'setup.dart';

Future<void> runServer(List<String> args) async {
  final server = FlutterMcpServer();
  await server.run();
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
          "serverInfo": {"name": "flutter-skill-mcp", "version": "2.0.0"},
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
          },
        },
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
        "description": "Trigger hot reload",
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

      if (_flutterProcess != null) {
        _flutterProcess!.kill();
        _flutterProcess = null;
      }

      final processArgs = ['run'];
      if (deviceId != null) processArgs.addAll(['-d', deviceId]);

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

      default:
        throw Exception("Unknown tool: $name");
    }
  }

  void _requireConnection() {
    if (_client == null || !_client!.isConnected) {
      throw Exception("Not connected. Call 'connect_app' or 'launch_app' first.");
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
      "error": {"code": code, "message": message},
    }));
  }
}
