import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import '../flutter_skill_client.dart';
import '../diagnostics/error_reporter.dart';
import 'setup.dart';

const String _currentVersion = '0.3.1';

/// Session information for multi-session support
class SessionInfo {
  final String id;
  final String name;
  final String projectPath;
  final String deviceId;
  final int port;
  final String vmServiceUri;
  final DateTime createdAt;

  SessionInfo({
    required this.id,
    required this.name,
    required this.projectPath,
    required this.deviceId,
    required this.port,
    required this.vmServiceUri,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'project_path': projectPath,
        'device_id': deviceId,
        'port': port,
        'vm_service_uri': vmServiceUri,
        'created_at': createdAt.toIso8601String(),
      };
}

Future<void> runServer(List<String> args) async {
  // Check for updates in background
  _checkForUpdates();

  // Acquire lock to prevent multiple instances
  final lockFile = await _acquireLock();
  if (lockFile == null) {
    stderr.writeln('ERROR: Another flutter-skill server is already running.');
    stderr.writeln('If you believe this is an error, delete: ~/.flutter_skill.lock');
    exit(1);
  }

  try {
    final server = FlutterMcpServer();
    await server.run();
  } finally {
    // Release lock on exit
    await _releaseLock(lockFile);
  }
}

/// Check pub.dev for newer version
Future<void> _checkForUpdates() async {
  try {
    final response = await http
        .get(
          Uri.parse('https://pub.dev/api/packages/flutter_skill'),
        )
        .timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final latestVersion = data['latest']?['version'] as String?;

      if (latestVersion != null &&
          _isNewerVersion(latestVersion, _currentVersion)) {
        stderr.writeln('');
        stderr.writeln(
            '╔══════════════════════════════════════════════════════════╗');
        stderr.writeln(
            '║  flutter-skill v$latestVersion available (current: v$_currentVersion)');
        stderr.writeln(
            '║                                                          ║');
        stderr.writeln(
            '║  Update with:                                            ║');
        stderr.writeln(
            '║    dart pub global activate flutter_skill                ║');
        stderr.writeln(
            '║  Or:                                                     ║');
        stderr.writeln(
            '║    npm update -g flutter-skill-mcp                       ║');
        stderr.writeln(
            '╚══════════════════════════════════════════════════════════╝');
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
  // Multi-session support
  final Map<String, FlutterSkillClient> _clients = {};
  final Map<String, SessionInfo> _sessions = {};
  String? _activeSessionId;

  // Legacy single client support (for backward compatibility)
  FlutterSkillClient? get _client => _activeSessionId != null
      ? _clients[_activeSessionId]
      : _clients.values.isNotEmpty
          ? _clients.values.first
          : null;

  set _client(FlutterSkillClient? client) {
    if (client != null && _activeSessionId != null) {
      _clients[_activeSessionId!] = client;
    }
  }

  Process? _flutterProcess;

  Future<void> run() async {
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
          "capabilities": {"tools": {}, "resources": {}},
          "protocolVersion": "2024-11-05",
          "serverInfo": {
            "name": "flutter-skill-mcp",
            "version": _currentVersion
          },
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
    } catch (e, stackTrace) {
      if (id != null) {
        _sendError(id, -32603, "Internal error: $e");
      }

      // Auto-report critical errors
      if (_shouldReportError(e)) {
        // Auto-report is enabled by default (can be disabled with env var)
        final autoReport =
            Platform.environment['FLUTTER_SKILL_AUTO_REPORT'] != 'false';

        await errorReporter.reportError(
          errorType: e.runtimeType.toString(),
          errorMessage: e.toString(),
          stackTrace: stackTrace,
          context: {
            'method': method,
            'params': params,
            'client_connected': _client?.isConnected ?? false,
          },
          autoCreate: autoReport,
        );
      }
    }
  }

  List<Map<String, dynamic>> _getToolsList() {
    return [
      // Session Management
      {
        "name": "list_sessions",
        "description": """List all active Flutter app sessions.

Returns information about all connected sessions including session ID, project path, device, and URI.
Use this to see available sessions before switching or closing them.""",
        "inputSchema": {
          "type": "object",
          "properties": {},
        },
      },
      {
        "name": "switch_session",
        "description": """Switch the active session to a different Flutter app.

After switching, all subsequent tool calls without an explicit session_id will use this session.
Use list_sessions() to see available session IDs.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Session ID to switch to"
            },
          },
          "required": ["session_id"],
        },
      },
      {
        "name": "close_session",
        "description": """Close and disconnect a specific session.

This will disconnect from the Flutter app and remove the session. The app will continue running.
If closing the active session, the next session becomes active automatically.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Session ID to close"
            },
          },
          "required": ["session_id"],
        },
      },

      // Connection
      {
        "name": "connect_app",
        "description": """Connect to a running Flutter App VM Service using specific URI.

[USE WHEN]
• You have a specific VM Service URI (ws://...)
• Reconnecting to a known app instance

[ALTERNATIVES]
• If you don't have URI: use scan_and_connect() to auto-find
• If app not running: use launch_app() to start it

[MULTI-SESSION]
Returns a session_id that can be used to target this specific app in subsequent tool calls.
Omitting session_id in other tools will use the active session.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "uri": {
              "type": "string",
              "description": "WebSocket URI (ws://...)"
            },
            "session_id": {
              "type": "string",
              "description": "Optional session ID (auto-generated if not provided)"
            },
            "name": {
              "type": "string",
              "description": "Optional session name for identification"
            },
          },
          "required": ["uri"],
        },
      },
      {
        "name": "launch_app",
        "description": """⚡ PRIORITY TOOL FOR UI TESTING ⚡

[TRIGGER KEYWORDS]
✓ English: test app | run app | launch | simulator | emulator | iOS test | Android test | E2E test | verify feature | validate UI | integration test | UI automation
✓ 中文: 测试应用 | 运行app | 启动应用 | 模拟器测试 | iOS测试 | Android测试 | 验证功能 | 界面测试 | 集成测试 | UI自动化

[PRIMARY PURPOSE]
Launch and test a Flutter app on iOS simulator/Android emulator for UI validation and interaction testing.

[USE WHEN]
• User wants to test/verify a Flutter feature or UI behavior
• User mentions iOS simulator or Android emulator
• User needs to validate user flows or interactions
• User asks to automate UI testing scenarios

[DO NOT USE]
✗ Unit testing (use 'flutter test' command instead)
✗ Widget testing (use WidgetTester instead)
✗ Code analysis or reading source files
✗ Building APK/IPA (use 'flutter build' instead)

[WORKFLOW]
1. Launch app on device/simulator
2. Auto-connect to VM Service
3. Ready for: inspect() → tap() → enter_text() → screenshot()

[FLUTTER 3.x COMPATIBILITY]
⚠️ Flutter 3.x uses DTD protocol by default. This tool requires VM Service protocol.
If launch fails with "getVM method not found" or "no VM Service URI":
• Solution: Add --vm-service-port flag to extra_args
• Example: launch_app(extra_args: ["--vm-service-port=50000"])
• Alternative: Use Dart MCP tools for DTD-based testing

[MULTI-SESSION]
Returns a session_id that can be used to target this specific app in subsequent tool calls.
Omitting session_id in other tools will use the active session.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "project_path": {
              "type": "string",
              "description": "Path to Flutter project"
            },
            "device_id": {"type": "string", "description": "Target device"},
            "dart_defines": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Dart defines (e.g. ['ENV=staging', 'DEBUG=true'])"
            },
            "extra_args": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Additional flutter run arguments"
            },
            "flavor": {"type": "string", "description": "Build flavor"},
            "target": {
              "type": "string",
              "description": "Target file (e.g. lib/main_staging.dart)"
            },
            "session_id": {
              "type": "string",
              "description": "Optional session ID (auto-generated if not provided)"
            },
            "name": {
              "type": "string",
              "description": "Optional session name for identification"
            },
          },
        },
      },
      {
        "name": "scan_and_connect",
        "description": """⚡ AUTO-CONNECT TOOL ⚡

[TRIGGER KEYWORDS]
✓ English: connect to app | find running app | auto-connect | connect to running Flutter | find app | detect app
✓ 中文: 连接应用 | 查找运行的应用 | 自动连接 | 连接运行中的Flutter | 查找app | 检测应用

[PRIMARY PURPOSE]
Automatically scan for and connect to a running Flutter app (scans VM Service ports 50000-50100).

[USE WHEN]
• App is already running and you want to connect
• Alternative to launch_app when app is already started
• Quick reconnection to running app

[WORKFLOW]
Scans ports, finds first Flutter app, auto-connects. If no app found, use launch_app instead.

[MULTI-SESSION]
Returns a session_id that can be used to target this specific app in subsequent tool calls.
Omitting session_id in other tools will use the active session.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "port_start": {
              "type": "integer",
              "description": "Start of port range (default: 50000)"
            },
            "port_end": {
              "type": "integer",
              "description": "End of port range (default: 50100)"
            },
            "session_id": {
              "type": "string",
              "description": "Optional session ID (auto-generated if not provided)"
            },
            "name": {
              "type": "string",
              "description": "Optional session name for identification"
            },
          },
        },
      },
      {
        "name": "list_running_apps",
        "description":
            "List all running Flutter apps (VM Services) on the system",
        "inputSchema": {
          "type": "object",
          "properties": {
            "port_start": {
              "type": "integer",
              "description": "Start of port range (default: 50000)"
            },
            "port_end": {
              "type": "integer",
              "description": "End of port range (default: 50100)"
            },
          },
        },
      },
      {
        "name": "stop_app",
        "description": "Stop the currently connected/launched Flutter app",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID (defaults to active session)"
            },
          },
        },
      },
      {
        "name": "disconnect",
        "description":
            "Disconnect from the current Flutter app (without stopping it)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID (defaults to active session)"
            },
          },
        },
      },
      {
        "name": "get_connection_status",
        "description": "Get current connection status and app info. If session_id is provided, gets status for that specific session; otherwise uses active session.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID (defaults to active session)"
            },
          },
        },
      },

      // Basic Inspection
      {
        "name": "inspect",
        "description": """⚡ UI DISCOVERY TOOL ⚡

[TRIGGER KEYWORDS]
✓ English: what's on screen | list buttons | show elements | see UI | find element | inspect UI | what elements | interactive elements
✓ 中文: 屏幕上有什么 | 列出按钮 | 显示元素 | 查看界面 | 找元素 | 检查UI | 有哪些元素 | 可交互元素

[PRIMARY PURPOSE]
Discover and list all interactive UI elements currently visible on screen (buttons, text fields, switches, etc.).

[USE WHEN]
• User wants to know what UI elements are available
• Before performing tap/enter_text actions (to find element keys)
• User asks what's on the current screen/page
• Debugging UI issues or verifying element presence

[WORKFLOW]
Essential first step for any UI interaction. Returns element list with keys/texts for use with tap() and enter_text().

[MULTI-SESSION]
All action tools support optional session_id parameter. If omitted, uses the active session.
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_id": {
              "type": "string",
              "description": "Optional session ID (defaults to active session)"
            },
          },
        },
      },
      {
        "name": "get_widget_tree",
        "description": "Get the full widget tree structure",
        "inputSchema": {
          "type": "object",
          "properties": {
            "max_depth": {
              "type": "integer",
              "description": "Maximum tree depth (default: 10)"
            },
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
            "type": {
              "type": "string",
              "description": "Widget type name to search"
            },
          },
          "required": ["type"],
        },
      },

      // Basic Actions
      {
        "name": "tap",
        "description": """⚡ UI INTERACTION TOOL ⚡

[TRIGGER KEYWORDS]
✓ English: tap | click | press | select | activate | touch | hit button | click button | press button
✓ 中文: 点击 | 点 | 按 | 选择 | 触摸 | 激活 | 按按钮 | 点按钮

[PRIMARY PURPOSE]
Tap/click a button or any interactive UI element. Simulates real user touch/click interaction.

[SUPPORTED METHODS]
1. By Widget key: tap(key: "submit_button")
2. By visible text: tap(text: "Submit")
3. By coordinates: tap(x: 100, y: 200)  // Use center coordinates from inspect()

[USE WHEN]
• User asks to click/press/tap a button or element
• Testing button functionality or navigation
• Automating user interactions in UI flows

[WORKFLOW]
Call inspect() first to see available elements and their keys/texts/coordinates, then use tap() with one of the methods above.

[TIP FOR ICONS/IMAGES]
For elements without text (icons, images), use coordinates from inspect():
  inspect() returns: {"center": {"x": 30, "y": 22}}
  Then call: tap(x: 30, y: 22)
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Widget key"},
            "text": {"type": "string", "description": "Text to find"},
            "x": {"type": "number", "description": "X coordinate (use with y)"},
            "y": {"type": "number", "description": "Y coordinate (use with x)"},
          },
        },
      },
      {
        "name": "enter_text",
        "description": """⚡ TEXT INPUT TOOL ⚡

[TRIGGER KEYWORDS]
✓ English: enter text | type | input | fill in | write | fill form | enter email | enter password
✓ 中文: 输入文本 | 输入 | 填写 | 录入 | 键入 | 填表单 | 输入邮箱 | 输入密码

[PRIMARY PURPOSE]
Type text into text fields (email, password, search, forms, etc.). Simulates real user keyboard input.

[USE WHEN]
• User wants to fill in forms or input fields
• Testing login screens (email/password)
• Testing search functionality
• Automating data entry in UI flows

[WORKFLOW]
Call inspect() first to find TextField keys, then use enter_text() with key and text value.
""",
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
            "duration": {
              "type": "integer",
              "description": "Duration in ms (default: 500)"
            },
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
            "direction": {
              "type": "string",
              "enum": ["up", "down", "left", "right"]
            },
            "distance": {
              "type": "number",
              "description": "Swipe distance in pixels (default: 300)"
            },
            "key": {
              "type": "string",
              "description": "Start from element (optional)"
            },
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
            "timeout": {
              "type": "integer",
              "description": "Timeout in ms (default: 5000)"
            },
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
            "timeout": {
              "type": "integer",
              "description": "Timeout in ms (default: 5000)"
            },
          },
        },
      },

      // Screenshot
      {
        "name": "screenshot",
        "description": """⚡ VISUAL CAPTURE TOOL ⚡

[TRIGGER KEYWORDS]
✓ English: screenshot | take picture | capture screen | show me | how does it look | visual debugging | take photo | snap | show current screen
✓ 中文: 截图 | 截屏 | 拍照 | 给我看看 | 看起来怎样 | 可视化调试 | 抓屏 | 显示当前界面

[PRIMARY PURPOSE]
Capture a screenshot of the current app screen for visual inspection, debugging, or documentation.

[USE WHEN]
• User wants to see what the current screen looks like
• Visual debugging of UI issues
• Documenting app state or test results
• Verifying UI appearance after actions

[RETURNS]
Base64-encoded PNG image that can be displayed to user.

[DEFAULTS OPTIMIZED FOR WEB]
• quality: 0.5 (prevents token overflow, set to 1.0 for full quality)
• max_width: 800 (scales down large screens, set to null for original size)
• For high-quality screenshots, explicitly set: quality=1.0, max_width=null
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "quality": {
              "type": "number",
              "description":
                  "Image quality 0.1-1.0 (default: 0.5, lower = smaller file)"
            },
            "max_width": {
              "type": "integer",
              "description": "Maximum width in pixels (default: 800, null for original size)"
            },
          },
        },
      },
      {
        "name": "screenshot_region",
        "description": "Take a screenshot of a specific screen region",
        "inputSchema": {
          "type": "object",
          "properties": {
            "x": {
              "type": "number",
              "description": "X coordinate of top-left corner"
            },
            "y": {
              "type": "number",
              "description": "Y coordinate of top-left corner"
            },
            "width": {"type": "number", "description": "Width of region"},
            "height": {"type": "number", "description": "Height of region"},
          },
          "required": ["x", "y", "width", "height"],
        },
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
        "description":
            "Execute multiple actions in sequence. Reduces round-trip latency for complex test flows.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "actions": {
              "type": "array",
              "description": "List of actions to execute",
              "items": {
                "type": "object",
                "properties": {
                  "action": {
                    "type": "string",
                    "description":
                        "Action name (tap, enter_text, swipe, wait, screenshot, assert_visible, assert_text)"
                  },
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
            "stop_on_failure": {
              "type": "boolean",
              "description": "Stop execution on first failure (default: true)"
            },
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
            "duration": {
              "type": "integer",
              "description": "Duration in ms (default: 500)"
            },
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
            "duration": {
              "type": "integer",
              "description": "Duration in ms (default: 300)"
            },
          },
          "required": ["start_x", "start_y", "end_x", "end_y"],
        },
      },
      {
        "name": "edge_swipe",
        "description":
            "Swipe from screen edge (for drawer menus, back gestures)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "edge": {
              "type": "string",
              "enum": ["left", "right", "top", "bottom"],
              "description": "Screen edge to start from"
            },
            "direction": {
              "type": "string",
              "enum": ["up", "down", "left", "right"],
              "description": "Swipe direction"
            },
            "distance": {
              "type": "number",
              "description": "Swipe distance in pixels (default: 200)"
            },
          },
          "required": ["edge", "direction"],
        },
      },
      {
        "name": "gesture",
        "description":
            "Perform a gesture with preset or custom coordinates. Presets: drawer_open, drawer_close, pull_refresh, page_back, swipe_left, swipe_right",
        "inputSchema": {
          "type": "object",
          "properties": {
            "preset": {
              "type": "string",
              "enum": [
                "drawer_open",
                "drawer_close",
                "pull_refresh",
                "page_back",
                "swipe_left",
                "swipe_right"
              ],
              "description": "Use a predefined gesture"
            },
            "from_x": {
              "type": "number",
              "description": "Custom start X (0.0-1.0 as ratio, or pixels)"
            },
            "from_y": {
              "type": "number",
              "description": "Custom start Y (0.0-1.0 as ratio, or pixels)"
            },
            "to_x": {
              "type": "number",
              "description": "Custom end X (0.0-1.0 as ratio, or pixels)"
            },
            "to_y": {
              "type": "number",
              "description": "Custom end Y (0.0-1.0 as ratio, or pixels)"
            },
            "duration": {
              "type": "integer",
              "description": "Gesture duration in ms (default: 300)"
            },
          },
        },
      },
      {
        "name": "wait_for_idle",
        "description":
            "Wait for the app to become idle (no animations, no pending frames)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "timeout": {
              "type": "integer",
              "description": "Maximum wait time in ms (default: 5000)"
            },
            "min_idle_time": {
              "type": "integer",
              "description":
                  "Minimum idle duration to confirm stability (default: 500)"
            },
          },
        },
      },

      // === NEW: Smart Scroll ===
      {
        "name": "scroll_until_visible",
        "description":
            "Scroll in a direction until target element becomes visible",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {"type": "string", "description": "Target element key"},
            "text": {"type": "string", "description": "Target element text"},
            "direction": {
              "type": "string",
              "enum": ["up", "down", "left", "right"],
              "description": "Scroll direction (default: down)"
            },
            "max_scrolls": {
              "type": "integer",
              "description": "Maximum scroll attempts (default: 10)"
            },
            "scrollable_key": {
              "type": "string",
              "description": "Key of the scrollable container (optional)"
            },
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
            "timeout": {
              "type": "integer",
              "description": "Wait timeout in ms (default: 5000)"
            },
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
            "timeout": {
              "type": "integer",
              "description": "Wait timeout in ms (default: 5000)"
            },
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
            "expected": {
              "type": "string",
              "description": "Expected text content"
            },
            "contains": {
              "type": "boolean",
              "description": "Use contains instead of equals (default: false)"
            },
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
            "expected_count": {
              "type": "integer",
              "description": "Expected count"
            },
            "min_count": {
              "type": "integer",
              "description": "Minimum count (alternative to exact)"
            },
            "max_count": {
              "type": "integer",
              "description": "Maximum count (alternative to exact)"
            },
          },
        },
      },

      // === NEW: Page State ===
      {
        "name": "get_page_state",
        "description":
            "Get complete page state snapshot (route, scroll position, focused element, keyboard, loading indicators)",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "get_interactable_elements",
        "description":
            "Get all interactable elements on current screen with suggested actions",
        "inputSchema": {
          "type": "object",
          "properties": {
            "include_positions": {
              "type": "boolean",
              "description": "Include x/y positions (default: true)"
            },
          },
        },
      },

      // === NEW: Performance & Memory ===
      {
        "name": "get_frame_stats",
        "description":
            "Get frame rendering statistics (FPS, jank, build/raster times)",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "get_memory_stats",
        "description": "Get memory usage statistics (heap, external)",
        "inputSchema": {"type": "object", "properties": {}},
      },

      // === Smart Diagnosis ===
      {
        "name": "diagnose",
        "description":
            "Analyze logs and UI state to detect issues and provide fix suggestions. Returns structured diagnosis with issues, suggestions, and next steps.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "scope": {
              "type": "string",
              "enum": ["all", "logs", "ui", "performance"],
              "description": "Diagnosis scope (default: all)"
            },
            "log_lines": {
              "type": "integer",
              "description":
                  "Number of recent log lines to analyze (default: 100)"
            },
            "include_screenshot": {
              "type": "boolean",
              "description": "Include screenshot in diagnosis (default: false)"
            },
          },
        },
      },
    ];
  }

  /// Get the client for a specific session or the active session
  FlutterSkillClient? _getClient(Map<String, dynamic> args) {
    final sessionId = args['session_id'] as String?;

    if (sessionId != null) {
      return _clients[sessionId];
    }

    // Use active session or first available
    return _client;
  }

  /// Generate a unique session ID
  String _generateSessionId() {
    return 'session_${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<dynamic> _executeTool(String name, Map<String, dynamic> args) async {
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
        _activeSessionId = _sessions.keys.isNotEmpty ? _sessions.keys.first : null;
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
            name: args['name'] as String? ?? 'Connection ${_sessions.length + 1}',
            projectPath: args['project_path'] as String? ?? 'unknown',
            deviceId: args['device_id'] as String? ?? 'unknown',
            port: int.tryParse(uri.split(':').last.split('/').first) ?? 0,
            vmServiceUri: uri,
          );

          // Set as active session if it's the first one
          if (_activeSessionId == null) {
            _activeSessionId = sessionId;
          }

          return {
            "success": true,
            "message": "Connected to $uri",
            "uri": uri,
            "session_id": sessionId,
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
        // Example: "The Dart VM service is listening on http://127.0.0.1:50753/xxxx=/"
        if (line.contains('VM service') || line.contains('Observatory')) {
          final vmRegex = RegExp(r'http://[a-zA-Z0-9.:\-_/=]+/');
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
                name: args['name'] as String? ?? 'App on ${deviceId ?? 'device'}',
                projectPath: projectPath,
                deviceId: deviceId?.toString() ?? 'unknown',
                port: int.tryParse(uri.split(':').last.split('/').first) ?? 0,
                vmServiceUri: uri,
              );

              // Set as active session if it's the first one
              if (_activeSessionId == null) {
                _activeSessionId = sessionId;
              }

              completer.complete("Launched and connected to $uri");
            }).catchError((e) {
              completer.completeError("Found VM Service URI but failed to connect: $e");
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
            completer.completeError("Flutter app exited normally but no connection established");
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

    if (name == 'scan_and_connect') {
      final portStart = args['port_start'] ?? 50000;
      final portEnd = args['port_end'] ?? 50100;
      final sessionId = args['session_id'] as String? ?? _generateSessionId();

      final vmServices = await _scanVmServices(portStart, portEnd);
      if (vmServices.isEmpty) {
        return {"success": false, "message": "No running Flutter apps found"};
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
        name: args['name'] as String? ?? 'Scanned connection ${_sessions.length + 1}',
        projectPath: args['project_path'] as String? ?? 'unknown',
        deviceId: args['device_id'] as String? ?? 'unknown',
        port: int.tryParse(uri.split(':').last.split('/').first) ?? 0,
        vmServiceUri: uri,
      );

      // Set as active session if it's the first one
      if (_activeSessionId == null) {
        _activeSessionId = sessionId;
      }

      return {
        "success": true,
        "connected": uri,
        "session_id": sessionId,
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
          _activeSessionId = _sessions.keys.isNotEmpty ? _sessions.keys.first : null;
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
        await _clients[sessionId]!.disconnect();
        _clients.remove(sessionId);
        _sessions.remove(sessionId);

        // Update active session
        if (_activeSessionId == sessionId) {
          _activeSessionId = _sessions.keys.isNotEmpty ? _sessions.keys.first : null;
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
          "session_id": sessionId,
          "uri": client.vmServiceUri,
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

    if (name == 'pub_search') {
      final query = args['query'];
      final url = Uri.parse('https://pub.dev/api/search?q=$query');
      final response = await http.get(url);
      if (response.statusCode != 200) throw Exception("Pub search failed");
      final json = jsonDecode(response.body);
      return json['packages'];
    }

    if (name == 'hot_reload') {
      final client = _getClient(args);
      _requireConnection(client);
      await client!.hotReload();
      return "Hot reload triggered";
    }

    if (name == 'hot_restart') {
      final client = _getClient(args);
      _requireConnection(client);
      await client!.hotRestart();
      return "Hot restart triggered";
    }

    // Require connection for all other tools
    final client = _getClient(args);
    _requireConnection(client);

    switch (name) {
      // Inspection
      case 'inspect':
        return await client!.getInteractiveElements();
      case 'get_widget_tree':
        final maxDepth = args['max_depth'] ?? 10;
        return await client!.getWidgetTree(maxDepth: maxDepth);
      case 'get_widget_properties':
        return await client!.getWidgetProperties(args['key']);
      case 'get_text_content':
        return await client!.getTextContent();
      case 'find_by_type':
        return await client!.findByType(args['type']);

      // Basic Actions
      case 'tap':
        // Support three methods: key, text, or coordinates
        final x = args['x'] as num?;
        final y = args['y'] as num?;

        // Method 3: Tap by coordinates
        if (x != null && y != null) {
          await client!.tapAt(x.toDouble(), y.toDouble());
          return {
            "success": true,
            "method": "coordinates",
            "message": "Tapped at ($x, $y)",
            "position": {"x": x, "y": y},
          };
        }

        // Method 1 & 2: Tap by key or text
        final result = await client!.tap(key: args['key'], text: args['text']);
        if (result['success'] != true) {
          // Return full error details including suggestions
          return {
            "success": false,
            "error": result['error'] ?? {"message": "Element not found"},
            "target":
                result['target'] ?? {"key": args['key'], "text": args['text']},
            if (result['suggestions'] != null)
              "suggestions": result['suggestions'],
          };
        }
        return {
          "success": true,
          "method": args['key'] != null ? "key" : "text",
          "message": "Tapped",
          if (result['position'] != null) "position": result['position'],
        };

      case 'enter_text':
        final result = await client!.enterText(args['key'], args['text']);
        if (result['success'] != true) {
          return {
            "success": false,
            "error": result['error'] ?? {"message": "TextField not found"},
            "target": result['target'] ?? {"key": args['key']},
            if (result['suggestions'] != null)
              "suggestions": result['suggestions'],
          };
        }
        return {"success": true, "message": "Text entered"};

      case 'scroll_to':
        final result =
            await client!.scrollTo(key: args['key'], text: args['text']);
        if (result['success'] != true) {
          return {
            "success": false,
            "error": result['message'] ?? "Element not found",
          };
        }
        return {"success": true, "message": "Scrolled"};

      // Advanced Actions
      case 'long_press':
        final duration = args['duration'] ?? 500;
        final success = await client!.longPress(
            key: args['key'], text: args['text'], duration: duration);
        return success ? "Long pressed" : "Long press failed";
      case 'double_tap':
        final success =
            await client!.doubleTap(key: args['key'], text: args['text']);
        return success ? "Double tapped" : "Double tap failed";
      case 'swipe':
        final distance = (args['distance'] ?? 300).toDouble();
        final success = await client!.swipe(
            direction: args['direction'], distance: distance, key: args['key']);
        return success ? "Swiped ${args['direction']}" : "Swipe failed";
      case 'drag':
        final success = await client!
            .drag(fromKey: args['from_key'], toKey: args['to_key']);
        return success ? "Dragged" : "Drag failed";

      // State & Validation
      case 'get_text_value':
        return await client!.getTextValue(args['key']);
      case 'get_checkbox_state':
        return await client!.getCheckboxState(args['key']);
      case 'get_slider_value':
        return await client!.getSliderValue(args['key']);
      case 'wait_for_element':
        final timeout = args['timeout'] ?? 5000;
        final found = await client!.waitForElement(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"found": found};
      case 'wait_for_gone':
        final timeout = args['timeout'] ?? 5000;
        final gone = await client!.waitForGone(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"gone": gone};

      // Screenshot
      case 'screenshot':
        // Default to lower quality and max width to prevent token overflow
        final quality = (args['quality'] as num?)?.toDouble() ?? 0.5;
        final maxWidth = args['max_width'] as int? ?? 800;
        final image =
            await client!.takeScreenshot(quality: quality, maxWidth: maxWidth);
        return {"image": image, "quality": quality, "max_width": maxWidth};

      case 'screenshot_region':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final width = (args['width'] as num).toDouble();
        final height = (args['height'] as num).toDouble();
        final image = await client!.takeRegionScreenshot(x, y, width, height);
        return {
          "image": image,
          "region": {"x": x, "y": y, "width": width, "height": height}
        };

      case 'screenshot_element':
        final image = await client!.takeElementScreenshot(args['key']);
        return {"image": image};

      // Navigation
      case 'get_current_route':
        return await client!.getCurrentRoute();
      case 'go_back':
        final success = await client!.goBack();
        return success ? "Navigated back" : "Cannot go back";
      case 'get_navigation_stack':
        return await client!.getNavigationStack();

      // Debug & Logs
      case 'get_logs':
        return await client!.getLogs();
      case 'get_errors':
        return await client!.getErrors();
      case 'clear_logs':
        await client!.clearLogs();
        return "Logs cleared";
      case 'get_performance':
        return await client!.getPerformance();

      // === NEW: Batch Operations ===
      case 'execute_batch':
        return await _executeBatch(args, client!);

      // === NEW: Coordinate-based Actions ===
      case 'tap_at':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        await client!.tapAt(x, y);
        return {"success": true, "action": "tap_at", "x": x, "y": y};

      case 'long_press_at':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final duration = args['duration'] ?? 500;
        await client!.longPressAt(x, y, duration: duration);
        return {"success": true, "action": "long_press_at", "x": x, "y": y};

      case 'swipe_coordinates':
        final startX = (args['start_x'] as num).toDouble();
        final startY = (args['start_y'] as num).toDouble();
        final endX = (args['end_x'] as num).toDouble();
        final endY = (args['end_y'] as num).toDouble();
        final duration = args['duration'] ?? 300;
        await client!
            .swipeCoordinates(startX, startY, endX, endY, duration: duration);
        return {"success": true, "action": "swipe_coordinates"};

      case 'edge_swipe':
        final edge = args['edge'] as String;
        final direction = args['direction'] as String;
        final distance = (args['distance'] as num?)?.toDouble() ?? 200;
        final result = await client!
            .edgeSwipe(edge: edge, direction: direction, distance: distance);
        return result;

      case 'gesture':
        return await _performGesture(args, client!);

      case 'wait_for_idle':
        return await _waitForIdle(args, client!);

      // === NEW: Smart Scroll ===
      case 'scroll_until_visible':
        return await _scrollUntilVisible(args, client!);

      // === NEW: Assertions ===
      case 'assert_visible':
        return await _assertVisible(args, client!, shouldBeVisible: true);

      case 'assert_not_visible':
        return await _assertVisible(args, client!, shouldBeVisible: false);

      case 'assert_text':
        return await _assertText(args, client!);

      case 'assert_element_count':
        return await _assertElementCount(args, client!);

      // === NEW: Page State ===
      case 'get_page_state':
        return await _getPageState(client!);

      case 'get_interactable_elements':
        final includePositions = args['include_positions'] ?? true;
        return await client!
            .getInteractiveElements(includePositions: includePositions);

      // === NEW: Performance & Memory ===
      case 'get_frame_stats':
        return await client!.getFrameStats();

      case 'get_memory_stats':
        return await client!.getMemoryStats();

      // === Smart Diagnosis ===
      case 'diagnose':
        return await _performDiagnosis(args, client!);

      default:
        throw Exception("Unknown tool: $name");
    }
  }

  /// Execute a batch of actions in sequence
  Future<Map<String, dynamic>> _executeBatch(
      Map<String, dynamic> args, FlutterSkillClient client) async {
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
            final tapResult =
                await client!.tap(key: action['key'], text: action['text']);
            if (tapResult['success'] != true) {
              throw Exception(tapResult['message'] ?? "Element not found");
            }
            result = "Tapped";
            break;

          case 'enter_text':
            final enterResult = await client!
                .enterText(action['key'], action['text'] ?? action['value']);
            if (enterResult['success'] != true) {
              throw Exception(enterResult['message'] ?? "TextField not found");
            }
            result = "Entered text";
            break;

          case 'swipe':
            final distance = (action['distance'] ?? 300).toDouble();
            await client!.swipe(
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
            final image = await client!.takeScreenshot();
            result = {"image": image};
            break;

          case 'assert_visible':
            final timeout = action['timeout'] ?? 5000;
            final found = await client!.waitForElement(
              key: action['key'],
              text: action['text'],
              timeout: timeout,
            );
            if (!found) throw Exception("Element not visible");
            result = "Visible";
            break;

          case 'assert_text':
            final actual = await client!.getTextValue(action['key']);
            final expected = action['expected'];
            if (actual != expected) {
              throw Exception(
                  "Text mismatch: expected '$expected', got '$actual'");
            }
            result = "Text matches";
            break;

          case 'long_press':
            final duration = action['duration'] ?? 500;
            await client!.longPress(
                key: action['key'], text: action['text'], duration: duration);
            result = "Long pressed";
            break;

          case 'double_tap':
            await client!.doubleTap(key: action['key'], text: action['text']);
            result = "Double tapped";
            break;

          case 'scroll_to':
            await client!.scrollTo(key: action['key'], text: action['text']);
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

  /// Gesture presets for common interactions
  /// Normalize VM Service URI to ensure correct format
  String _normalizeVmServiceUri(String uri) {
    // Remove trailing slash
    uri = uri.trimRight();
    if (uri.endsWith('/')) {
      uri = uri.substring(0, uri.length - 1);
    }

    // Handle http:// -> ws://
    if (uri.startsWith('http://')) {
      uri = uri.replaceFirst('http://', 'ws://');
    }

    // Ensure /ws suffix for VM Service
    if (!uri.endsWith('/ws') && !uri.contains('/ws?')) {
      // Check if it's a base URL like ws://127.0.0.1:50000/xxx=
      if (uri.contains('=') && !uri.endsWith('/ws')) {
        uri = '$uri/ws';
      }
    }

    return uri;
  }

  static const Map<String, Map<String, dynamic>> _gesturePresets = {
    'drawer_open': {
      'from_x': 0.0,
      'from_y': 0.5,
      'to_x': 0.75,
      'to_y': 0.5,
      'duration': 300,
    },
    'drawer_close': {
      'from_x': 0.75,
      'from_y': 0.5,
      'to_x': 0.0,
      'to_y': 0.5,
      'duration': 300,
    },
    'pull_refresh': {
      'from_x': 0.5,
      'from_y': 0.15,
      'to_x': 0.5,
      'to_y': 0.6,
      'duration': 500,
    },
    'page_back': {
      'from_x': 0.02,
      'from_y': 0.5,
      'to_x': 0.8,
      'to_y': 0.5,
      'duration': 250,
    },
    'swipe_left': {
      'from_x': 0.8,
      'from_y': 0.5,
      'to_x': 0.2,
      'to_y': 0.5,
      'duration': 300,
    },
    'swipe_right': {
      'from_x': 0.2,
      'from_y': 0.5,
      'to_x': 0.8,
      'to_y': 0.5,
      'duration': 300,
    },
  };

  /// Perform gesture with preset or custom coordinates
  Future<Map<String, dynamic>> _performGesture(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final preset = args['preset'] as String?;
    final duration = args['duration'] as int? ?? 300;

    double fromX, fromY, toX, toY;
    int gestureDuration = duration;

    if (preset != null) {
      final presetConfig = _gesturePresets[preset];
      if (presetConfig == null) {
        return {
          "success": false,
          "error": {
            "code": "E102",
            "message": "Unknown gesture preset: $preset",
          },
          "available_presets": _gesturePresets.keys.toList(),
        };
      }
      fromX = presetConfig['from_x'] as double;
      fromY = presetConfig['from_y'] as double;
      toX = presetConfig['to_x'] as double;
      toY = presetConfig['to_y'] as double;
      gestureDuration = presetConfig['duration'] as int? ?? duration;
    } else {
      // Custom coordinates
      fromX = (args['from_x'] as num?)?.toDouble() ?? 0.5;
      fromY = (args['from_y'] as num?)?.toDouble() ?? 0.5;
      toX = (args['to_x'] as num?)?.toDouble() ?? 0.5;
      toY = (args['to_y'] as num?)?.toDouble() ?? 0.5;
    }

    // Get screen size to convert ratios to pixels
    final layoutTree = await client!.getLayoutTree();
    final screenWidth =
        (layoutTree['size']?['width'] as num?)?.toDouble() ?? 400.0;
    final screenHeight =
        (layoutTree['size']?['height'] as num?)?.toDouble() ?? 800.0;

    // Convert ratios (0.0-1.0) to pixels if values are small
    final startX = fromX <= 1.0 ? fromX * screenWidth : fromX;
    final startY = fromY <= 1.0 ? fromY * screenHeight : fromY;
    final endX = toX <= 1.0 ? toX * screenWidth : toX;
    final endY = toY <= 1.0 ? toY * screenHeight : toY;

    await client!.swipeCoordinates(startX, startY, endX, endY,
        duration: gestureDuration);

    return {
      "success": true,
      "gesture": preset ?? "custom",
      "from": {"x": startX.round(), "y": startY.round()},
      "to": {"x": endX.round(), "y": endY.round()},
      "duration": gestureDuration,
    };
  }

  /// Wait for the app to become idle
  Future<Map<String, dynamic>> _waitForIdle(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final timeout = args['timeout'] as int? ?? 5000;
    final minIdleTime = args['min_idle_time'] as int? ?? 500;

    final stopwatch = Stopwatch()..start();
    var lastActivityTime = DateTime.now();
    var previousTree = '';

    while (stopwatch.elapsedMilliseconds < timeout) {
      // Get current widget tree snapshot
      final tree = await client!.getWidgetTree(maxDepth: 3);
      final currentTree = tree.toString();

      if (currentTree == previousTree) {
        // No changes detected
        final idleTime =
            DateTime.now().difference(lastActivityTime).inMilliseconds;
        if (idleTime >= minIdleTime) {
          return {
            "success": true,
            "idle": true,
            "idle_time_ms": idleTime,
            "total_wait_ms": stopwatch.elapsedMilliseconds,
          };
        }
      } else {
        // Activity detected, reset idle timer
        lastActivityTime = DateTime.now();
        previousTree = currentTree;
      }

      await Future.delayed(const Duration(milliseconds: 100));
    }

    return {
      "success": false,
      "idle": false,
      "message": "Timeout waiting for idle state",
      "timeout_ms": timeout,
      "total_wait_ms": stopwatch.elapsedMilliseconds,
    };
  }

  /// Scroll until element becomes visible
  Future<Map<String, dynamic>> _scrollUntilVisible(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final key = args['key'] as String?;
    final text = args['text'] as String?;
    final direction = args['direction'] ?? 'down';
    final maxScrolls = args['max_scrolls'] ?? 10;
    final scrollableKey = args['scrollable_key'] as String?;

    for (var i = 0; i < maxScrolls; i++) {
      // Check if element is visible
      final found = await client!.waitForElement(
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
      await client!.swipe(
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
  Future<Map<String, dynamic>> _assertVisible(Map<String, dynamic> args,
      FlutterSkillClient client, {required bool shouldBeVisible}) async {
    final key = args['key'] as String?;
    final text = args['text'] as String?;
    final timeout = args['timeout'] ?? 5000;

    if (shouldBeVisible) {
      final found =
          await client!.waitForElement(key: key, text: text, timeout: timeout);
      return {
        "success": found,
        "assertion": "visible",
        "element": key ?? text,
        "message": found
            ? "Element is visible"
            : "Element not found within ${timeout}ms",
      };
    } else {
      final gone =
          await client!.waitForGone(key: key, text: text, timeout: timeout);
      return {
        "success": gone,
        "assertion": "not_visible",
        "element": key ?? text,
        "message": gone
            ? "Element is not visible"
            : "Element still visible after ${timeout}ms",
      };
    }
  }

  /// Assert text content
  Future<Map<String, dynamic>> _assertText(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final key = args['key'] as String;
    final expected = args['expected'] as String;
    final useContains = args['contains'] ?? false;

    final actual = await client!.getTextValue(key);

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
  Future<Map<String, dynamic>> _assertElementCount(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final type = args['type'] as String?;
    final text = args['text'] as String?;
    final expectedCount = args['expected_count'] as int?;
    final minCount = args['min_count'] as int?;
    final maxCount = args['max_count'] as int?;

    int count = 0;

    if (type != null) {
      final elements = await client!.findByType(type);
      count = elements.length;
    } else if (text != null) {
      final allText = await client!.getTextContent();
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
  Future<Map<String, dynamic>> _getPageState(FlutterSkillClient client) async {
    final route = await client!.getCurrentRoute();
    final interactables = await client!.getInteractiveElements();
    final textContent = await client!.getTextContent();

    return {
      "route": route,
      "interactive_elements_count": (interactables as List?)?.length ?? 0,
      "text_content_preview": textContent
          .toString()
          .substring(0, textContent.toString().length.clamp(0, 500)),
      "timestamp": DateTime.now().toIso8601String(),
    };
  }

  void _requireConnection([FlutterSkillClient? client]) {
    client ??= _client;
    if (client == null) {
      throw Exception('''Not connected to Flutter app.

Solutions:
1. If app is already running: call scan_and_connect() to auto-detect and connect
2. To start a new app: call launch_app(project_path: "/path/to/project")
3. If you have the VM Service URI: call connect_app(uri: "ws://...")

Tip: Use get_connection_status() to see available running apps or list_sessions() to see all sessions.''');
    }

    if (!client.isConnected) {
      // Connection lost - note: with multi-session, we don't clean up here
      throw Exception('''Connection to Flutter app was lost.

Please reconnect using one of these methods:
1. scan_and_connect() - Auto-detect running apps
2. connect_app(uri: "ws://...") - Connect to specific URI
3. launch_app(project_path: "...") - Launch new app instance''');
    }
  }

  /// Determine if an error should be auto-reported to GitHub
  bool _shouldReportError(dynamic error) {
    final errorStr = error.toString().toLowerCase();

    // Report these critical errors
    final criticalPatterns = [
      'lateinitializationerror',
      'null check operator',
      'unhandledexception',
      'stackoverflow',
      'outofmemory',
    ];

    // Don't report these expected errors
    final ignoredPatterns = [
      'not connected',
      'no isolates found',
      'connection refused',
      'timeout',
    ];

    // Check if it's a critical error
    for (final pattern in criticalPatterns) {
      if (errorStr.contains(pattern)) {
        // Make sure it's not an ignored error
        for (final ignored in ignoredPatterns) {
          if (errorStr.contains(ignored)) return false;
        }
        return true;
      }
    }

    return false;
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
      final socket = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 200));
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

  // ==================== Smart Diagnosis ====================

  /// Diagnose patterns for log analysis
  static const List<Map<String, dynamic>> _diagnosisPatterns = [
    // Network errors
    {
      'pattern': r'DioException.*connection',
      'type': 'network_connection_error',
      'severity': 'critical',
      'message': 'API connection failed',
      'suggestion': {
        'action': 'Check network and API configuration',
        'steps': [
          '1. Verify device network connection',
          '2. Check if API endpoint is accessible',
          '3. If using local mock, ensure server is running',
        ],
      },
      'next_step': {
        'tool': 'tap',
        'params': {'text': 'Retry'},
        'description': 'Tap retry button'
      },
    },
    {
      'pattern': r'SocketException',
      'type': 'network_connection_error',
      'severity': 'critical',
      'message': 'Socket connection failed',
      'suggestion': {
        'action': 'Check network connectivity',
        'steps': [
          '1. Verify network connection',
          '2. Check firewall settings',
          '3. Verify server is running',
        ],
      },
      'next_step': {
        'tool': 'hot_restart',
        'params': {},
        'description': 'Restart app to retry connection'
      },
    },
    {
      'pattern': r'TimeoutException',
      'type': 'network_timeout',
      'severity': 'critical',
      'message': 'Request timeout',
      'suggestion': {
        'action': 'Handle slow network or server',
        'steps': [
          '1. Check server response time',
          '2. Consider increasing timeout',
          '3. Check for network congestion',
        ],
      },
      'next_step': {
        'tool': 'tap',
        'params': {'text': 'Retry'},
        'description': 'Retry the operation'
      },
    },
    // Layout errors
    {
      'pattern': r'RenderFlex overflowed',
      'type': 'layout_overflow',
      'severity': 'warning',
      'message': 'Layout overflow detected',
      'suggestion': {
        'action': 'Fix layout overflow',
        'steps': [
          '1. Use Expanded or Flexible to wrap child widgets',
          '2. Add SingleChildScrollView for scrollable content',
          '3. Check fixed sizes and constraints',
        ],
        'code_example': '''// Before: Row(children: [Text('Long text...')])
// After: Row(children: [Expanded(child: Text('Long text...', overflow: TextOverflow.ellipsis))])''',
      },
      'next_step': {
        'tool': 'hot_reload',
        'params': {},
        'description': 'Hot reload after fixing code'
      },
    },
    // Null errors
    {
      'pattern': r'Null check operator',
      'type': 'null_check_error',
      'severity': 'critical',
      'message': 'Null check failed',
      'suggestion': {
        'action': 'Handle null value properly',
        'steps': [
          '1. Check data loading state before accessing',
          '2. Use null-aware operators (?., ??)',
          '3. Add proper null checks',
        ],
      },
      'next_step': {
        'tool': 'hot_restart',
        'params': {},
        'description': 'Restart after fixing null issue'
      },
    },
    // State errors
    {
      'pattern': r'setState.*disposed',
      'type': 'state_error',
      'severity': 'warning',
      'message': 'setState called on disposed widget',
      'suggestion': {
        'action': 'Check mounted state before setState',
        'steps': [
          '1. Add if (mounted) before setState',
          '2. Cancel async operations in dispose()',
          '3. Use proper lifecycle management',
        ],
        'code_example': '''// Add mounted check
if (mounted) {
  setState(() { ... });
}''',
      },
      'next_step': {
        'tool': 'hot_reload',
        'params': {},
        'description': 'Hot reload after fixing'
      },
    },
    // Memory warnings
    {
      'pattern': r'memory.*warning|OutOfMemory',
      'type': 'memory_high',
      'severity': 'warning',
      'message': 'High memory usage detected',
      'suggestion': {
        'action': 'Optimize memory usage',
        'steps': [
          '1. Check for large images not being disposed',
          '2. Use ListView.builder instead of ListView',
          '3. Cancel streams and timers in dispose()',
        ],
      },
      'next_step': {
        'tool': 'hot_restart',
        'params': {},
        'description': 'Restart to free memory'
      },
    },
  ];

  /// Perform comprehensive diagnosis
  Future<Map<String, dynamic>> _performDiagnosis(
      Map<String, dynamic> args, FlutterSkillClient client) async {
    final scope = args['scope'] ?? 'all';
    // ignore: unused_local_variable
    final logLines = args['log_lines'] ?? 100; // Reserved for future use
    final includeScreenshot = args['include_screenshot'] ?? false;

    final issues = <Map<String, dynamic>>[];
    final suggestions = <Map<String, dynamic>>[];
    final nextSteps = <Map<String, dynamic>>[];
    var issueCounter = 1;

    // Analyze logs if scope includes logs
    if (scope == 'all' || scope == 'logs') {
      try {
        final logs = await client!.getLogs();
        final logsStr = logs.toString();

        // Check each pattern
        for (final pattern in _diagnosisPatterns) {
          final regex =
              RegExp(pattern['pattern'] as String, caseSensitive: false);
          if (regex.hasMatch(logsStr)) {
            final issueId = 'E${issueCounter.toString().padLeft(3, '0')}';
            issueCounter++;

            issues.add({
              'id': issueId,
              'type': pattern['type'],
              'severity': pattern['severity'],
              'message': pattern['message'],
            });

            final suggestion = pattern['suggestion'] as Map<String, dynamic>;
            suggestions.add({
              'for_issue': issueId,
              'priority': pattern['severity'] == 'critical' ? 1 : 2,
              ...suggestion,
            });

            if (pattern['next_step'] != null) {
              nextSteps.add({
                ...pattern['next_step'] as Map<String, dynamic>,
                'for_issue': issueId,
              });
            }
          }
        }
      } catch (e) {
        // Log analysis failed, continue with other diagnostics
      }
    }

    // Analyze UI state if scope includes UI
    if (scope == 'all' || scope == 'ui') {
      try {
        final elements = await client!.getInteractiveElements();

        // Check for empty state
        if (elements.isEmpty) {
          final issueId = 'E${issueCounter.toString().padLeft(3, '0')}';
          issueCounter++;

          issues.add({
            'id': issueId,
            'type': 'empty_state',
            'severity': 'warning',
            'message': 'No interactive elements found on screen',
          });

          suggestions.add({
            'for_issue': issueId,
            'priority': 2,
            'action': 'Check page loading state',
            'steps': [
              '1. Verify data loaded successfully',
              '2. Check if showing loading indicator',
              '3. Review error handling logic',
            ],
          });

          nextSteps.add({
            'tool': 'screenshot',
            'params': {},
            'description': 'Take screenshot to inspect current state',
            'for_issue': issueId,
          });
        }
      } catch (e) {
        // UI analysis failed
      }
    }

    // Analyze performance if scope includes performance
    if (scope == 'all' || scope == 'performance') {
      try {
        final memoryStats = await client!.getMemoryStats();
        final heapUsed = memoryStats['heapUsed'] as int? ?? 0;
        final heapMB = heapUsed / (1024 * 1024);

        // Check high memory usage (> 300MB)
        if (heapMB > 300) {
          final issueId = 'E${issueCounter.toString().padLeft(3, '0')}';
          issueCounter++;

          issues.add({
            'id': issueId,
            'type': 'memory_high',
            'severity': heapMB > 500 ? 'critical' : 'warning',
            'message':
                'Memory usage ${heapMB.toStringAsFixed(1)}MB exceeds 300MB threshold',
          });

          suggestions.add({
            'for_issue': issueId,
            'priority': heapMB > 500 ? 1 : 2,
            'action': 'Reduce memory usage',
            'steps': [
              '1. Dispose large images when not visible',
              '2. Use ListView.builder for long lists',
              '3. Check for memory leaks in streams/timers',
            ],
          });

          nextSteps.add({
            'tool': 'hot_restart',
            'params': {},
            'description': 'Restart app to release memory',
            'for_issue': issueId,
          });
        }
      } catch (e) {
        // Performance analysis failed
      }
    }

    // Calculate health score
    final criticalCount =
        issues.where((i) => i['severity'] == 'critical').length;
    final warningCount = issues.where((i) => i['severity'] == 'warning').length;
    final healthScore =
        (100 - (criticalCount * 30) - (warningCount * 10)).clamp(0, 100);

    // Build result
    final result = <String, dynamic>{
      'success': true,
      'timestamp': DateTime.now().toIso8601String(),
      'summary': {
        'total_issues': issues.length,
        'critical': criticalCount,
        'warning': warningCount,
        'info': issues.where((i) => i['severity'] == 'info').length,
        'health_score': healthScore,
      },
      'issues': issues,
      'suggestions': suggestions,
      'next_steps': nextSteps,
    };

    // Include screenshot if requested
    if (includeScreenshot) {
      try {
        final screenshot = await client!.takeScreenshot();
        result['screenshot'] = screenshot;
      } catch (e) {
        // Screenshot failed
      }
    }

    return result;
  }

  // ==================== End Smart Diagnosis ====================

  // ==================== Build Error Helpers ====================

  /// Get suggestions based on build error message
  List<String> _getBuildErrorSuggestions(String errorMessage) {
    final suggestions = <String>[];
    final lowerError = errorMessage.toLowerCase();

    // iOS specific errors
    if (lowerError.contains('xcode') || lowerError.contains('cocoapods')) {
      suggestions.addAll([
        'iOS Build Error Detected',
        '',
        'Common fixes:',
      ]);

      if (lowerError.contains('webrtc') || lowerError.contains('pod')) {
        suggestions.addAll([
          '1. Clean and reinstall CocoaPods:',
          '   cd ios && rm -rf Pods Podfile.lock && pod install',
          '',
          '2. Clean Flutter build cache:',
          '   flutter clean && flutter pub get',
          '',
          '3. If still failing, clear Xcode cache:',
          '   rm -rf ~/Library/Developer/Xcode/DerivedData',
        ]);
      } else if (lowerError.contains('signing') ||
          lowerError.contains('provisioning')) {
        suggestions.addAll([
          '1. Check Xcode signing settings',
          '2. Verify Apple Developer account',
          '3. Update provisioning profiles',
        ]);
      } else {
        suggestions.addAll([
          '1. Try: flutter clean && flutter pub get',
          '2. Try: cd ios && pod install',
          '3. Check Xcode version compatibility',
        ]);
      }
    }

    // Android specific errors
    else if (lowerError.contains('gradle') || lowerError.contains('android')) {
      suggestions.addAll([
        'Android Build Error Detected',
        '',
        '1. Clean and rebuild:',
        '   flutter clean && flutter pub get',
        '',
        '2. Invalidate Gradle cache:',
        '   cd android && ./gradlew clean',
        '',
        '3. Check gradle-wrapper.properties version',
      ]);
    }

    // Dependency errors
    else if (lowerError.contains('dependency') ||
        lowerError.contains('version solving failed')) {
      suggestions.addAll([
        'Dependency Conflict Detected',
        '',
        '1. Run: flutter pub outdated',
        '2. Update dependencies: flutter pub upgrade',
        '3. Check pubspec.yaml for version conflicts',
      ]);
    }

    // General build errors
    else {
      suggestions.addAll([
        'Build Failed',
        '',
        '1. Run: flutter doctor -v',
        '2. Try: flutter clean && flutter pub get',
        '3. Check the error details above for specific issues',
      ]);
    }

    return suggestions;
  }

  /// Get quick fix commands based on error message
  Map<String, String> _getQuickFixes(String errorMessage, String projectPath) {
    final lowerError = errorMessage.toLowerCase();

    // iOS CocoaPods/WebRTC fix
    if (lowerError.contains('webrtc') ||
        (lowerError.contains('cocoapods') && lowerError.contains('pod'))) {
      return {
        'description': 'Clean and reinstall CocoaPods dependencies',
        'command':
            'cd $projectPath/ios && rm -rf Pods Podfile.lock .symlinks && pod deintegrate && pod install && cd ..',
        'platform': 'iOS',
      };
    }

    // General iOS build fix
    if (lowerError.contains('xcode') || lowerError.contains('ios')) {
      return {
        'description': 'Clean iOS build and Flutter cache',
        'command':
            'cd $projectPath && rm -rf ios/Pods ios/Podfile.lock build && flutter clean && flutter pub get',
        'platform': 'iOS',
      };
    }

    // Android build fix
    if (lowerError.contains('gradle') || lowerError.contains('android')) {
      return {
        'description': 'Clean Android build and Gradle cache',
        'command':
            'cd $projectPath && flutter clean && cd android && ./gradlew clean && cd ..',
        'platform': 'Android',
      };
    }

    // General fix
    return {
      'description': 'Clean Flutter build cache',
      'command': 'cd $projectPath && flutter clean && flutter pub get',
      'platform': 'All',
    };
  }

  // ==================== End Build Error Helpers ====================

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

// ==================== Lock Management ====================

/// Acquire a lock file to prevent multiple server instances
Future<File?> _acquireLock() async {
  final home = Platform.environment['HOME'];
  if (home == null) return null;

  final lockFile = File('$home/.flutter_skill.lock');

  // Check if lock exists and is stale (older than 10 minutes)
  if (await lockFile.exists()) {
    final stat = await lockFile.stat();
    final age = DateTime.now().difference(stat.modified);
    if (age.inMinutes < 10) {
      // Lock is fresh, another instance is likely running
      return null;
    }
    // Stale lock, remove it
    await lockFile.delete();
  }

  // Create lock file with current PID
  await lockFile.writeAsString('${pid}\n${DateTime.now().toIso8601String()}');
  return lockFile;
}

/// Release the lock file
Future<void> _releaseLock(File lockFile) async {
  try {
    if (await lockFile.exists()) {
      await lockFile.delete();
    }
  } catch (e) {
    // Ignore cleanup errors
  }
}
