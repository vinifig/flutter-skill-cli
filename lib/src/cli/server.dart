import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import '../discovery/bridge_discovery.dart';
import '../drivers/app_driver.dart';
import '../drivers/bridge_driver.dart';
import '../drivers/flutter_driver.dart';
import '../drivers/native_driver.dart';
import '../diagnostics/error_reporter.dart';
import 'setup.dart';

const String currentVersion = '0.7.7';

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
    stderr.writeln(
        'If you believe this is an error, delete: ~/.flutter_skill.lock');
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
          _isNewerVersion(latestVersion, currentVersion)) {
        stderr.writeln('');
        stderr.writeln(
            '╔══════════════════════════════════════════════════════════╗');
        stderr.writeln(
            '║  flutter-skill v$latestVersion available (current: v$currentVersion)');
        stderr.writeln(
            '║                                                          ║');
        stderr.writeln(
            '║  Update with:                                            ║');
        stderr.writeln(
            '║    dart pub global activate flutter_skill                ║');
        stderr.writeln(
            '║  Or:                                                     ║');
        stderr.writeln(
            '║    npm update -g flutter-skill                       ║');
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
  final Map<String, AppDriver> _clients = {};
  final Map<String, SessionInfo> _sessions = {};
  String? _activeSessionId;

  // Legacy single client support (for backward compatibility)
  AppDriver? get _client => _activeSessionId != null
      ? _clients[_activeSessionId]
      : _clients.values.isNotEmpty
          ? _clients.values.first
          : null;

  Process? _flutterProcess;

  // Native platform drivers (for interacting with native OS views)
  final Map<String, NativeDriver> _nativeDrivers = {};

  /// Get or create native driver for the active session
  Future<NativeDriver?> _getNativeDriver(Map<String, dynamic> args) async {
    final sessionId = args['session_id'] as String? ?? _activeSessionId;
    final key = sessionId ?? '_default';

    if (_nativeDrivers.containsKey(key)) return _nativeDrivers[key];

    String? deviceId;
    if (sessionId != null && _sessions.containsKey(sessionId)) {
      deviceId = _sessions[sessionId]!.deviceId;
    }

    final driver = await NativeDriver.create(deviceId);
    if (driver != null) {
      _nativeDrivers[key] = driver;
    }
    return driver;
  }

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
          "serverInfo": {"name": "flutter-skill", "version": currentVersion},
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
        "description":
            """Connect to a running Flutter App VM Service using specific URI.

[USE WHEN]
• You have a specific VM Service URI (ws://...)
• Reconnecting to a known app instance

[ALTERNATIVES]
• If you don't have URI: use scan_and_connect() to auto-find
• If app not running: use launch_app() to start it

[AUTO-FIX]
If project_path is provided, automatically checks and fixes missing configuration:
• Adds flutter_skill dependency to pubspec.yaml if missing
• Adds FlutterSkillBinding initialization to main.dart if missing

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
            "project_path": {
              "type": "string",
              "description":
                  "Optional: Project path for auto-fix configuration check"
            },
            "session_id": {
              "type": "string",
              "description":
                  "Optional session ID (auto-generated if not provided)"
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
test app | run app | launch | simulator | emulator | iOS test | Android test | E2E test | verify feature | validate UI | integration test | UI automation | start app | debug app

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
              "description":
                  "Optional session ID (auto-generated if not provided)"
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
connect to app | find running app | auto-connect | connect to running Flutter | find app | detect app | scan for app | discover app

[PRIMARY PURPOSE]
Automatically scan for and connect to a running Flutter app (scans VM Service ports 50000-50100).

[USE WHEN]
• App is already running and you want to connect
• Alternative to launch_app when app is already started
• Quick reconnection to running app

[WORKFLOW]
Scans ports, finds first Flutter app, auto-connects. If no app found, use launch_app instead.

[AUTO-FIX]
If project_path is provided, automatically checks and fixes missing configuration:
• Adds flutter_skill dependency to pubspec.yaml if missing
• Adds FlutterSkillBinding initialization to main.dart if missing

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
            "project_path": {
              "type": "string",
              "description":
                  "Optional: Project path for auto-fix configuration check"
            },
            "session_id": {
              "type": "string",
              "description":
                  "Optional session ID (auto-generated if not provided)"
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
        "description":
            "Get current connection status and app info. If session_id is provided, gets status for that specific session; otherwise uses active session.",
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
what's on screen | list buttons | show elements | see UI | find element | inspect UI | what elements | interactive elements | get widgets | discover components

[PRIMARY PURPOSE]
Discover and list all interactive UI elements currently visible on screen (buttons, text fields, switches, etc.).

[USE WHEN]
• User wants to know what UI elements are available
• Before performing tap/enter_text actions (to find element keys)
• User asks what's on the current screen/page
• Debugging UI issues or verifying element presence

[WORKFLOW]
Essential first step for any UI interaction. Returns element list with keys/texts for use with tap() and enter_text().

[OUTPUT FORMAT]
Each element includes:
• key: Element identifier for targeting
• type: Widget type (Button, TextField, etc.)
• bounds/center: Position coordinates
• coordinatesReliable: Boolean flag indicating if coordinates are trustworthy
• warning: Present if coordinates are unreliable (e.g., TextField at (0,0))

[IMPORTANT]
⚠️ TextFields may report (0,0) coordinates if not fully laid out. Check 'coordinatesReliable' flag.
   When false, use 'key' or 'text' for targeting instead of coordinates.

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
            "current_page_only": {
              "type": "boolean",
              "description":
                  "Filter to only show elements on the current visible page (excludes elements with negative coordinates or not visible). Default: true"
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
        "description": """Find widgets by type name

[PRIMARY PURPOSE]
Search for all widgets matching a specific type (e.g., "TextField", "Button", "ListTile").

[USAGE]
find_by_type(type: "TextField")  // Finds all TextFields
find_by_type(type: "Button")     // Finds all button types

[OUTPUT FORMAT]
Returns list of widgets with:
• type: Full widget type name
• key: Element identifier if available
• position: {x, y} coordinates
• size: {width, height} dimensions
• coordinatesReliable: Boolean - true if coordinates are trustworthy

[IMPORTANT]
⚠️ Check 'coordinatesReliable' flag before using coordinates for tap/click actions.
   If false, use 'key' property for reliable targeting.
""",
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
tap | click | press | select | activate | touch | hit button | click button | press button | trigger | push

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
enter text | type | input | fill in | write | fill form | enter email | enter password | set value | submit text

[PRIMARY PURPOSE]
Type text into text fields (email, password, search, forms, etc.). Simulates real user keyboard input.

[USE WHEN]
• User wants to fill in forms or input fields
• Testing login screens (email/password)
• Testing search functionality
• Automating data entry in UI flows

[WORKFLOW]
Option 1: Call inspect() to find TextField keys, then enter_text(key: "field_key", text: "value").
Option 2: Tap a TextField first, then enter_text(text: "value") without key - enters into focused field.
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "key": {
              "type": "string",
              "description":
                  "TextField key (optional - if omitted, enters text into the currently focused TextField)"
            },
            "text": {"type": "string", "description": "Text to enter"},
          },
          "required": ["text"],
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
screenshot | take picture | capture screen | show me | how does it look | visual debugging | take photo | snap | show current screen | grab screen | print screen

[PRIMARY PURPOSE]
Capture a screenshot of the current app screen for visual inspection, debugging, or documentation.

[USE WHEN]
• User wants to see what the current screen looks like
• Visual debugging of UI issues
• Documenting app state or test results
• Verifying UI appearance after actions

[RETURNS]
By default, saves screenshot to a temporary file and returns file path. Optionally can return base64-encoded PNG image.

[DEFAULTS OPTIMIZED FOR USABILITY]
• save_to_file: true (saves to file, returns path - recommended for large images)
• quality: 0.5 (prevents token overflow, set to 1.0 for full quality)
• max_width: 800 (scales down large screens, set to null for original size)
• For high-quality screenshots, explicitly set: quality=1.0, max_width=null
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "save_to_file": {
              "type": "boolean",
              "description":
                  "Save to file and return path (default: true, recommended)",
              "default": true
            },
            "quality": {
              "type": "number",
              "description":
                  "Image quality 0.1-1.0 (default: 0.5, lower = smaller file)"
            },
            "max_width": {
              "type": "integer",
              "description":
                  "Maximum width in pixels (default: 800, null for original size)"
            },
          },
        },
      },
      {
        "name": "screenshot_region",
        "description":
            "Take a screenshot of a specific screen region. Defaults to saving as file to prevent token overflow.",
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
            "save_to_file": {
              "type": "boolean",
              "description":
                  "Save to temp file instead of returning base64 (default: true)"
            },
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
            "text": {"type": "string", "description": "Text to find"},
          },
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
        "description": "Get application errors with pagination support",
        "inputSchema": {
          "type": "object",
          "properties": {
            "limit": {
              "type": "integer",
              "description": "Maximum number of errors to return (default: 50)"
            },
            "offset": {
              "type": "integer",
              "description": "Number of errors to skip (default: 0)"
            },
          },
        },
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

      // HTTP / Network Monitoring
      {
        "name": "get_network_requests",
        "description": """⚡ NETWORK MONITOR ⚡

[TRIGGER KEYWORDS]
api response | network request | http response | check api | what api called | network traffic | http status | api result

[PRIMARY PURPOSE]
View HTTP/API requests made by the app. Shows URL, method, status code, duration, and response body.
Use after tap/interaction to verify what API calls were triggered.

[USE WHEN]
• After tapping a button to check what API was called
• Verifying login/signup API responses
• Debugging network issues
• Checking API response data after user actions

[WORKFLOW]
1. Call enable_network_monitoring() first (one-time setup)
2. Perform actions (tap, enter_text, etc.)
3. Call get_network_requests() to see API calls made

[OUTPUT]
Each request includes: method, url, status_code, duration_ms, response_body (truncated)
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "limit": {
              "type": "integer",
              "description":
                  "Maximum number of requests to return (default: 20)"
            },
          },
        },
      },
      {
        "name": "enable_network_monitoring",
        "description":
            "Enable HTTP/network request monitoring. Call once before using get_network_requests.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "enable": {
              "type": "boolean",
              "description":
                  "Enable (true) or disable (false) monitoring. Default: true"
            },
          },
        },
      },
      {
        "name": "clear_network_requests",
        "description": "Clear captured network request history",
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
        // Native platform interaction tools
        "name": "native_screenshot",
        "description": """Take a screenshot at the OS level (bypasses Flutter).

[USE WHEN]
• A native dialog is shown (photo picker, permission dialog, share sheet)
• Flutter's screenshot returns a blank/stale image
• You need to see system-level UI (status bar, keyboard, etc.)
• The app is presenting a platform view not rendered by Flutter

[HOW IT WORKS]
• iOS Simulator: Uses xcrun simctl screenshot
• Android Emulator: Uses adb shell screencap

[RETURNS]
Screenshot saved to a temporary file (default) or base64-encoded PNG.
This captures the ENTIRE device screen, not just the Flutter app content.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "save_to_file": {
              "type": "boolean",
              "description": "Save to file and return path (default: true)"
            },
          },
        },
      },
      {
        "name": "native_tap",
        "description":
            """Tap at device coordinates using OS-level input (bypasses Flutter).

[USE WHEN]
• Interacting with native dialogs (photo picker, permission "Allow", share sheet)
• Flutter's tap() doesn't work because the target is a native view
• Tapping system UI elements (status bar, notification)

[HOW IT WORKS]
• iOS Simulator: Uses macOS Accessibility API to find and press UI elements at device coordinates
• Android Emulator: Uses adb shell input tap

[IMPORTANT]
• Coordinates are in device pixels (same as native_screenshot dimensions)
• Take a native_screenshot first to identify tap targets
• iOS: No external tools needed (uses built-in osascript + Accessibility API)
• The Simulator window must be visible and not minimized""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "x": {
              "type": "number",
              "description": "X coordinate in device pixels"
            },
            "y": {
              "type": "number",
              "description": "Y coordinate in device pixels"
            },
          },
          "required": ["x", "y"],
        },
      },
      {
        "name": "native_input_text",
        "description": """Enter text using OS-level input (bypasses Flutter).

[USE WHEN]
• Typing into native text fields (search bars in native pickers, etc.)
• Flutter's enter_text() doesn't work because the field is in a native view
• Entering text in system dialogs

[HOW IT WORKS]
• iOS Simulator: Copies text to pasteboard via simctl, then pastes with Cmd+V
• Android Emulator: Uses adb shell input text

[IMPORTANT]
• The target text field must already be focused (tap it first with native_tap)
• iOS method uses paste, so it replaces clipboard content
• iOS paste confirmation dialog ("Allow Paste") is automatically dismissed""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "text": {"type": "string", "description": "Text to enter"},
          },
          "required": ["text"],
        },
      },
      {
        "name": "native_swipe",
        "description": """Swipe using OS-level input (bypasses Flutter).

[USE WHEN]
• Swiping in native views (photo gallery scroll, native list)
• Dismissing native dialogs with swipe
• Flutter's swipe doesn't work because the scrollable is a native view

[HOW IT WORKS]
• iOS Simulator: Uses macOS Accessibility API scroll actions on elements at device coordinates
• Android Emulator: Uses adb shell input swipe

[IMPORTANT]
• Coordinates are in device pixels
• Take a native_screenshot first to plan your swipe path
• iOS: Scrolls by page using accessibility actions (AXScrollUpByPage/AXScrollDownByPage)""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "start_x": {
              "type": "number",
              "description": "Start X in device pixels"
            },
            "start_y": {
              "type": "number",
              "description": "Start Y in device pixels"
            },
            "end_x": {
              "type": "number",
              "description": "End X in device pixels"
            },
            "end_y": {
              "type": "number",
              "description": "End Y in device pixels"
            },
            "duration": {
              "type": "integer",
              "description": "Swipe duration in ms (default: 300)"
            },
          },
          "required": ["start_x", "start_y", "end_x", "end_y"],
        },
      },
      {
        "name": "diagnose_project",
        "description": """⚡ DIAGNOSTIC & AUTO-FIX TOOL ⚡

[TRIGGER KEYWORDS]
diagnose | check configuration | verify setup | fix config | configuration problem | setup issue | missing dependency | not configured

[PRIMARY PURPOSE]
Diagnose Flutter project configuration and automatically fix common issues.

[USE WHEN]
• Connection problems ("not connected", "VM Service not found")
• Setup verification before testing
• Troubleshooting configuration issues
• First-time project setup

[CHECKS PERFORMED]
• pubspec.yaml - flutter_skill dependency
• lib/main.dart - FlutterSkillBinding initialization
• Running processes - Flutter app status
• Port availability - VM Service ports

[AUTO-FIX OPTIONS]
• auto_fix: true (default) - Automatically fix detected issues
• auto_fix: false - Only report issues without fixing

[RETURNS]
Detailed diagnostic report with:
• Configuration status (✅/❌)
• Detected issues
• Auto-fix results
• Recommendations""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "project_path": {
              "type": "string",
              "description":
                  "Path to Flutter project (default: current directory)"
            },
            "auto_fix": {
              "type": "boolean",
              "description": "Automatically fix detected issues (default: true)"
            },
          },
        },
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

      // Test Indicators
      {
        "name": "enable_test_indicators",
        "description":
            "Enable visual indicators for test actions (tap, swipe, long press, text input)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "enabled": {
              "type": "boolean",
              "description": "Enable or disable indicators",
              "default": true
            },
            "style": {
              "type": "string",
              "description":
                  "Indicator style: minimal (fast, small), standard (default), detailed (slow, large with debug info)",
              "enum": ["minimal", "standard", "detailed"],
              "default": "standard"
            },
          },
        },
      },
      {
        "name": "get_indicator_status",
        "description": "Get current test indicator status",
        "inputSchema": {"type": "object", "properties": {}},
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
  AppDriver? _getClient(Map<String, dynamic> args) {
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

      // Try bridge discovery first (cross-framework)
      final bridgeApps = await BridgeDiscovery.discoverAll();
      if (bridgeApps.isNotEmpty) {
        final bridgeApp = bridgeApps.first;

        // Disconnect old client for this session if exists
        if (_clients.containsKey(sessionId)) {
          await _clients[sessionId]!.disconnect();
        }

        final driver = BridgeDriver.fromInfo(bridgeApp);
        await driver.connect();

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
        await _clients[sessionId]!.disconnect();
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
      final fc = _asFlutterClient(client!, 'hot_restart');
      await fc.hotRestart();
      return "Hot restart triggered";
    }

    if (name == 'enable_test_indicators') {
      final client = _getClient(args);
      _requireConnection(client);
      final fc = _asFlutterClient(client!, 'enable_test_indicators');
      final enabled = args['enabled'] ?? true;
      final style = args['style'] ?? 'standard';

      if (enabled) {
        await fc.enableTestIndicators(style: style);
        return {
          "success": true,
          "enabled": true,
          "style": style,
          "message": "Test indicators enabled with $style style"
        };
      } else {
        await fc.disableTestIndicators();
        return {
          "success": true,
          "enabled": false,
          "message": "Test indicators disabled"
        };
      }
    }

    if (name == 'get_indicator_status') {
      final client = _getClient(args);
      _requireConnection(client);
      final fc = _asFlutterClient(client!, 'get_indicator_status');
      return await fc.getIndicatorStatus();
    }

    // Native platform interaction tools (no VM Service connection required)
    if (name == 'native_screenshot') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
          "suggestions": [
            "Ensure an iOS Simulator or Android emulator is running",
            "If using a physical device, native tools are not yet supported",
          ],
        };
      }
      final saveToFile = args['save_to_file'] ?? true;
      final result = await driver.screenshot(saveToFile: saveToFile);
      return result.toJson();
    }

    if (name == 'native_tap') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }

      final toolCheck = await driver.checkToolAvailability();
      final missingTools =
          toolCheck.entries.where((e) => !e.value).map((e) => e.key).toList();
      if (missingTools.isNotEmpty) {
        return {
          "success": false,
          "error": {
            "code": "E502",
            "message": "Missing required tools: ${missingTools.join(', ')}",
          },
          "suggestions": driver.platform == NativePlatform.iosSimulator
              ? [
                  "Ensure Xcode command line tools are installed: xcode-select --install"
                ]
              : [
                  "Install Android platform tools: brew install android-platform-tools"
                ],
        };
      }

      final x = (args['x'] as num).toDouble();
      final y = (args['y'] as num).toDouble();
      final result = await driver.tap(x, y);
      return result.toJson();
    }

    if (name == 'native_input_text') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      final text = args['text'] as String;
      final result = await driver.inputText(text);
      return result.toJson();
    }

    if (name == 'native_swipe') {
      final driver = await _getNativeDriver(args);
      if (driver == null) {
        return {
          "success": false,
          "error": {
            "code": "E501",
            "message": "No supported platform detected",
          },
        };
      }
      final startX = (args['start_x'] as num).toDouble();
      final startY = (args['start_y'] as num).toDouble();
      final endX = (args['end_x'] as num).toDouble();
      final endY = (args['end_y'] as num).toDouble();
      final duration = args['duration'] as int? ?? 300;
      final result =
          await driver.swipe(startX, startY, endX, endY, durationMs: duration);
      return result.toJson();
    }

    // Require connection for all other tools
    final client = _getClient(args);
    _requireConnection(client);
    switch (name) {
      // Inspection
      case 'inspect':
        final elements = await client!.getInteractiveElements();
        final currentPageOnly = args['current_page_only'] ?? true;
        if (currentPageOnly) {
          final filtered = elements.where((e) {
            if (e is! Map) return true;
            final bounds = e['bounds'];
            if (bounds == null) return true;
            final x = bounds['x'] as int? ?? 0;
            final y = bounds['y'] as int? ?? 0;
            final visible = e['visible'] ?? true;
            // Exclude elements with negative coordinates (off-screen / background pages)
            return visible == true && x >= -10 && y >= -10;
          }).toList();
          return filtered;
        }
        return elements;
      case 'get_widget_tree':
        final fc = _asFlutterClient(client!, 'get_widget_tree');
        final maxDepth = args['max_depth'] ?? 10;
        return await fc.getWidgetTree(maxDepth: maxDepth);
      case 'get_widget_properties':
        final fc = _asFlutterClient(client!, 'get_widget_properties');
        return await fc.getWidgetProperties(args['key']);
      case 'get_text_content':
        final fc = _asFlutterClient(client!, 'get_text_content');
        return await fc.getTextContent();
      case 'find_by_type':
        final fc = _asFlutterClient(client!, 'find_by_type');
        return await fc.findByType(args['type']);

      // Basic Actions
      case 'tap':
        // Support three methods: key, text, or coordinates
        final x = args['x'] as num?;
        final y = args['y'] as num?;

        // Method 3: Tap by coordinates (Flutter-specific)
        if (x != null && y != null) {
          final fc = _asFlutterClient(client!, 'tap (coordinates)');
          await fc.tapAt(x.toDouble(), y.toDouble());
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
        final fc = _asFlutterClient(client!, 'scroll_to');
        final result = await fc.scrollTo(key: args['key'], text: args['text']);
        if (result['success'] != true) {
          return {
            "success": false,
            "error": result['message'] ?? "Element not found",
          };
        }
        return {"success": true, "message": "Scrolled"};

      // Advanced Actions
      case 'long_press':
        final fc = _asFlutterClient(client!, 'long_press');
        final duration = args['duration'] ?? 500;
        final success = await fc.longPress(
            key: args['key'], text: args['text'], duration: duration);
        return success ? "Long pressed" : "Long press failed";
      case 'double_tap':
        final fc = _asFlutterClient(client!, 'double_tap');
        final success =
            await fc.doubleTap(key: args['key'], text: args['text']);
        return success ? "Double tapped" : "Double tap failed";
      case 'swipe':
        final distance = (args['distance'] ?? 300).toDouble();
        final success = await client!.swipe(
            direction: args['direction'], distance: distance, key: args['key']);
        return success ? "Swiped ${args['direction']}" : "Swipe failed";
      case 'drag':
        final fc = _asFlutterClient(client!, 'drag');
        final success =
            await fc.drag(fromKey: args['from_key'], toKey: args['to_key']);
        return success ? "Dragged" : "Drag failed";

      // State & Validation
      case 'get_text_value':
        final fc = _asFlutterClient(client!, 'get_text_value');
        return await fc.getTextValue(args['key']);
      case 'get_checkbox_state':
        final fc = _asFlutterClient(client!, 'get_checkbox_state');
        return await fc.getCheckboxState(args['key']);
      case 'get_slider_value':
        final fc = _asFlutterClient(client!, 'get_slider_value');
        return await fc.getSliderValue(args['key']);
      case 'wait_for_element':
        final fc = _asFlutterClient(client!, 'wait_for_element');
        final timeout = args['timeout'] ?? 5000;
        final found = await fc.waitForElement(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"found": found};
      case 'wait_for_gone':
        final fc = _asFlutterClient(client!, 'wait_for_gone');
        final timeout = args['timeout'] ?? 5000;
        final gone = await fc.waitForGone(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"gone": gone};

      // Screenshot
      case 'screenshot':
        // Default to lower quality and max width to prevent token overflow
        final quality = (args['quality'] as num?)?.toDouble() ?? 0.5;
        final maxWidth = args['max_width'] as int? ?? 800;
        final saveToFile =
            args['save_to_file'] ?? true; // Default to saving as file

        final imageBase64 =
            await client!.takeScreenshot(quality: quality, maxWidth: maxWidth);

        if (imageBase64 == null) {
          return {
            "success": false,
            "error": "Failed to capture screenshot",
            "message": "Screenshot returned null"
          };
        }

        if (saveToFile) {
          // Save to temporary file
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filename = 'flutter_skill_screenshot_$timestamp.png';
          final file = File('${tempDir.path}/$filename');

          // Decode base64 and write to file
          final bytes = base64.decode(imageBase64);
          await file.writeAsBytes(bytes);

          return {
            "success": true,
            "file_path": file.path,
            "filename": filename,
            "size_bytes": bytes.length,
            "quality": quality,
            "max_width": maxWidth,
            "format": "png",
            "message": "Screenshot saved to ${file.path}"
          };
        } else {
          // Return base64 (legacy behavior)
          return {
            "image": imageBase64,
            "quality": quality,
            "max_width": maxWidth,
            "warning":
                "Returning base64 data. Consider using save_to_file=true for large images."
          };
        }

      case 'screenshot_region':
        final fc = _asFlutterClient(client!, 'screenshot_region');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final width = (args['width'] as num).toDouble();
        final height = (args['height'] as num).toDouble();
        final saveToFile = args['save_to_file'] ?? true;
        final image = await fc.takeRegionScreenshot(x, y, width, height);

        if (image == null) {
          return {
            "success": false,
            "error": "Failed to capture region screenshot",
          };
        }

        if (saveToFile) {
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filename = 'flutter_skill_region_$timestamp.png';
          final file = File('${tempDir.path}/$filename');
          final bytes = base64.decode(image);
          await file.writeAsBytes(bytes);
          return {
            "success": true,
            "file_path": file.path,
            "size_bytes": bytes.length,
            "region": {"x": x, "y": y, "width": width, "height": height},
            "message": "Region screenshot saved to ${file.path}"
          };
        }

        return {
          "success": true,
          "image": image,
          "region": {"x": x, "y": y, "width": width, "height": height},
          "warning":
              "Returning base64 data. Consider using save_to_file=true for large regions."
        };

      case 'screenshot_element':
        // Support both key and text parameters
        String? targetKey = args['key'];

        // If text is provided, find the element first
        if (targetKey == null && args['text'] != null) {
          final elements = await client!.getInteractiveElements();
          final matchingElement = elements.firstWhere(
            (e) => e['text'] == args['text'],
            orElse: () => <String, dynamic>{},
          );
          targetKey = matchingElement['key'];
        }

        if (targetKey == null) {
          return {
            "error": "Element not found",
            "message":
                "No element found with key or text: ${args['key'] ?? args['text']}",
          };
        }

        final fc = _asFlutterClient(client!, 'screenshot_element');
        final image = await fc.takeElementScreenshot(targetKey);
        if (image == null) {
          return {
            "error": "Screenshot failed",
            "message": "Could not capture screenshot of element",
          };
        }
        return {"image": image};

      // Navigation
      case 'get_current_route':
        final fc = _asFlutterClient(client!, 'get_current_route');
        return await fc.getCurrentRoute();
      case 'go_back':
        final fc = _asFlutterClient(client!, 'go_back');
        final success = await fc.goBack();
        return success ? "Navigated back" : "Cannot go back";
      case 'get_navigation_stack':
        final fc = _asFlutterClient(client!, 'get_navigation_stack');
        return await fc.getNavigationStack();

      // Debug & Logs
      case 'get_logs':
        final logs = await client!.getLogs();
        return {
          "logs": logs,
          "summary": {
            "total_count": logs.length,
            "message": "${logs.length} log entries"
          }
        };
      case 'get_errors':
        final fc = _asFlutterClient(client!, 'get_errors');
        final allErrors = await fc.getErrors();
        final limit = int.tryParse('${args['limit'] ?? ''}') ?? 50;
        final offset = int.tryParse('${args['offset'] ?? ''}') ?? 0;
        final pagedErrors = allErrors.skip(offset).take(limit).toList();
        return {
          "errors": pagedErrors,
          "summary": {
            "total_count": allErrors.length,
            "returned_count": pagedErrors.length,
            "offset": offset,
            "limit": limit,
            "has_more": offset + limit < allErrors.length,
            "has_errors": allErrors.isNotEmpty,
            "message": allErrors.isEmpty
                ? "No errors found"
                : "${allErrors.length} error(s) total, showing ${pagedErrors.length} (offset: $offset)"
          }
        };
      case 'clear_logs':
        await client!.clearLogs();
        return {"success": true, "message": "Logs cleared successfully"};
      case 'get_performance':
        final fc = _asFlutterClient(client!, 'get_performance');
        return await fc.getPerformance();

      // === HTTP / Network Monitoring ===
      case 'enable_network_monitoring':
        final fc = _asFlutterClient(client!, 'enable_network_monitoring');
        final enable = args['enable'] ?? true;
        final success = await fc.enableHttpTimelineLogging(enable: enable);
        return {
          "success": success,
          "enabled": enable,
          "message": success
              ? "HTTP monitoring ${enable ? 'enabled' : 'disabled'}"
              : "Failed to enable HTTP monitoring (VM Service extension not available)",
          "usage": enable
              ? "Now perform actions, then call get_network_requests() to see API calls"
              : null,
        };

      case 'get_network_requests':
        final fc = _asFlutterClient(client!, 'get_network_requests');
        final limit = int.tryParse('${args['limit'] ?? ''}') ?? 20;
        // Try VM Service HTTP profile first (captures all dart:io HTTP)
        final profile = await fc.getHttpProfile();
        if (profile.containsKey('requests') && !profile.containsKey('error')) {
          final allRequests = (profile['requests'] as List?) ?? [];
          // Take latest N requests, format for readability
          final recentRequests = allRequests.length > limit
              ? allRequests.sublist(allRequests.length - limit)
              : allRequests;

          final formatted = recentRequests.map((r) {
            if (r is Map) {
              return {
                'id': r['id'],
                'method': r['method'],
                'uri': r['uri'],
                'status_code': r['response']?['statusCode'],
                'start_time': r['startTime'] != null
                    ? DateTime.fromMicrosecondsSinceEpoch(r['startTime'])
                        .toIso8601String()
                    : null,
                'end_time': r['endTime'] != null
                    ? DateTime.fromMicrosecondsSinceEpoch(r['endTime'])
                        .toIso8601String()
                    : null,
                'duration_ms': (r['endTime'] != null && r['startTime'] != null)
                    ? ((r['endTime'] - r['startTime']) / 1000).round()
                    : null,
                'content_type':
                    r['response']?['headers']?['content-type']?.toString(),
              };
            }
            return r;
          }).toList();

          return {
            "success": true,
            "source": "vm_service_http_profile",
            "requests": formatted,
            "total": allRequests.length,
            "returned": formatted.length,
            "message":
                "${formatted.length} of ${allRequests.length} HTTP requests"
          };
        }

        // Fallback: try manually logged requests from the binding
        final manualRequests = await fc.getHttpRequests(limit: limit);
        return {
          "success": true,
          "source": "manual_log",
          ...manualRequests,
          "hint":
              "For automatic HTTP capture, call enable_network_monitoring() first"
        };

      case 'clear_network_requests':
        final fc = _asFlutterClient(client!, 'clear_network_requests');
        await fc.clearHttpRequests();
        return {"success": true, "message": "Network request history cleared"};

      // === NEW: Batch Operations ===
      case 'execute_batch':
        final fc = _asFlutterClient(client!, 'execute_batch');
        return await _executeBatch(args, fc);

      // === NEW: Coordinate-based Actions ===
      case 'tap_at':
        final fc = _asFlutterClient(client!, 'tap_at');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        await fc.tapAt(x, y);
        return {"success": true, "action": "tap_at", "x": x, "y": y};

      case 'long_press_at':
        final fc = _asFlutterClient(client!, 'long_press_at');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final duration = args['duration'] ?? 500;
        await fc.longPressAt(x, y, duration: duration);
        return {"success": true, "action": "long_press_at", "x": x, "y": y};

      case 'swipe_coordinates':
        final fc = _asFlutterClient(client!, 'swipe_coordinates');
        final startX = (args['start_x'] as num).toDouble();
        final startY = (args['start_y'] as num).toDouble();
        final endX = (args['end_x'] as num).toDouble();
        final endY = (args['end_y'] as num).toDouble();
        final duration = args['duration'] ?? 300;
        await fc.swipeCoordinates(startX, startY, endX, endY,
            duration: duration);
        return {"success": true, "action": "swipe_coordinates"};

      case 'edge_swipe':
        final fc = _asFlutterClient(client!, 'edge_swipe');
        final edge = args['edge'] as String;
        final direction = args['direction'] as String;
        final distance = (args['distance'] as num?)?.toDouble() ?? 200;
        final result = await fc.edgeSwipe(
            edge: edge, direction: direction, distance: distance);
        return result;

      case 'gesture':
        final fc = _asFlutterClient(client!, 'gesture');
        return await _performGesture(args, fc);

      case 'wait_for_idle':
        final fc = _asFlutterClient(client!, 'wait_for_idle');
        return await _waitForIdle(args, fc);

      // === NEW: Smart Scroll ===
      case 'scroll_until_visible':
        final fc = _asFlutterClient(client!, 'scroll_until_visible');
        return await _scrollUntilVisible(args, fc);

      // === NEW: Assertions ===
      case 'assert_visible':
        final fc = _asFlutterClient(client!, 'assert_visible');
        return await _assertVisible(args, fc, shouldBeVisible: true);

      case 'assert_not_visible':
        final fc = _asFlutterClient(client!, 'assert_not_visible');
        return await _assertVisible(args, fc, shouldBeVisible: false);

      case 'assert_text':
        final fc = _asFlutterClient(client!, 'assert_text');
        return await _assertText(args, fc);

      case 'assert_element_count':
        final fc = _asFlutterClient(client!, 'assert_element_count');
        return await _assertElementCount(args, fc);

      // === NEW: Page State ===
      case 'get_page_state':
        final fc = _asFlutterClient(client!, 'get_page_state');
        return await _getPageState(fc);

      case 'get_interactable_elements':
        final includePositions = args['include_positions'] ?? true;
        return await client!
            .getInteractiveElements(includePositions: includePositions);

      // === NEW: Performance & Memory ===
      case 'get_frame_stats':
        final fc = _asFlutterClient(client!, 'get_frame_stats');
        return await fc.getFrameStats();

      case 'get_memory_stats':
        final fc = _asFlutterClient(client!, 'get_memory_stats');
        return await fc.getMemoryStats();

      // === Smart Diagnosis ===
      case 'diagnose':
        final fc = _asFlutterClient(client!, 'diagnose');
        return await _performDiagnosis(args, fc);

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
                await client.tap(key: action['key'], text: action['text']);
            if (tapResult['success'] != true) {
              throw Exception(tapResult['message'] ?? "Element not found");
            }
            result = "Tapped";
            break;

          case 'enter_text':
            final enterResult = await client.enterText(
                action['key'], action['text'] ?? action['value']);
            if (enterResult['success'] != true) {
              throw Exception(enterResult['message'] ?? "TextField not found");
            }
            result = "Entered text";
            break;

          case 'swipe':
            final distance = (action['distance'] ?? 300).toDouble();
            await client.swipe(
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
            final image = await client.takeScreenshot();
            result = {"image": image};
            break;

          case 'assert_visible':
            final timeout = action['timeout'] ?? 5000;
            final found = await client.waitForElement(
              key: action['key'],
              text: action['text'],
              timeout: timeout,
            );
            if (!found) throw Exception("Element not visible");
            result = "Visible";
            break;

          case 'assert_text':
            final actual = await client.getTextValue(action['key']);
            final expected = action['expected'];
            if (actual != expected) {
              throw Exception(
                  "Text mismatch: expected '$expected', got '$actual'");
            }
            result = "Text matches";
            break;

          case 'long_press':
            final duration = action['duration'] ?? 500;
            await client.longPress(
                key: action['key'], text: action['text'], duration: duration);
            result = "Long pressed";
            break;

          case 'double_tap':
            await client.doubleTap(key: action['key'], text: action['text']);
            result = "Double tapped";
            break;

          case 'scroll_to':
            await client.scrollTo(key: action['key'], text: action['text']);
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
      // Check if it's a base URL like ws://127.0.0.1:50000/xxx= or ws://127.0.0.1:50000/xxx#
      // Flutter 3.41+ uses # instead of =
      if ((uri.contains('=') || uri.contains('#')) && !uri.endsWith('/ws')) {
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
    final layoutTree = await client.getLayoutTree();
    final screenWidth =
        (layoutTree['size']?['width'] as num?)?.toDouble() ?? 400.0;
    final screenHeight =
        (layoutTree['size']?['height'] as num?)?.toDouble() ?? 800.0;

    // Convert ratios (0.0-1.0) to pixels if values are small
    final startX = fromX <= 1.0 ? fromX * screenWidth : fromX;
    final startY = fromY <= 1.0 ? fromY * screenHeight : fromY;
    final endX = toX <= 1.0 ? toX * screenWidth : toX;
    final endY = toY <= 1.0 ? toY * screenHeight : toY;

    await client.swipeCoordinates(startX, startY, endX, endY,
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
      final tree = await client.getWidgetTree(maxDepth: 3);
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
      final found = await client.waitForElement(
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
      await client.swipe(
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
  Future<Map<String, dynamic>> _assertVisible(
      Map<String, dynamic> args, FlutterSkillClient client,
      {required bool shouldBeVisible}) async {
    final key = args['key'] as String?;
    final text = args['text'] as String?;
    final timeout = args['timeout'] ?? 5000;

    if (shouldBeVisible) {
      final found =
          await client.waitForElement(key: key, text: text, timeout: timeout);
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
          await client.waitForGone(key: key, text: text, timeout: timeout);
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

    final actual = await client.getTextValue(key);

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
      final elements = await client.findByType(type);
      count = elements.length;
    } else if (text != null) {
      final allText = await client.getTextContent();
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
    final route = await client.getCurrentRoute();
    final interactables = await client.getInteractiveElements();
    final textContent = await client.getTextContent();

    return {
      "route": route,
      "interactive_elements_count": (interactables as List?)?.length ?? 0,
      "text_content_preview": textContent
          .toString()
          .substring(0, textContent.toString().length.clamp(0, 500)),
      "timestamp": DateTime.now().toIso8601String(),
    };
  }

  /// Cast an [AppDriver] to [FlutterSkillClient], throwing a clear error
  /// if the active connection is a bridge driver (non-Flutter).
  FlutterSkillClient _asFlutterClient(AppDriver driver, String toolName) {
    if (driver is FlutterSkillClient) return driver;
    throw Exception(
      '❌ "$toolName" requires a Flutter (VM Service) connection, '
      'but the active session uses the ${driver.frameworkName} bridge driver.\n'
      'This tool is not available for ${driver.frameworkName} apps.',
    );
  }

  void _requireConnection([AppDriver? client]) {
    client ??= _client;
    if (client == null) {
      throw Exception('''❌ Not connected to Flutter app.

📍 Current Status:
   • No active VM Service connection
   • Unable to interact with Flutter app

🔧 How to Connect:

   Option 1: Auto-detect Running App (Easiest)
   ───────────────────────────────────────────────
   scan_and_connect()
   → Automatically finds and connects to running Flutter apps on ports 50000-50100

   Option 2: Auto-launch App (Recommended)
   ───────────────────────────────────────────────
   launch_app(project_path: ".", device_id: "iPhone 16 Pro")
   → Starts app with VM Service enabled on port 50000

   Option 3: Manual Connect with URI
   ───────────────────────────────────────────────
   connect_app(uri: "ws://127.0.0.1:50000/abcd1234=/ws")
   → Connects to specific VM Service WebSocket URI

💡 Pro Tips:
   • Use get_connection_status() to see available running apps
   • Use list_sessions() to see all active connections
   • URI must start with "ws://" (WebSocket protocol)
   • Port 50000 is the default for flutter_skill

⚠️  Troubleshooting:
   • Ensure flutter_skill dependency is in your Flutter project
   • Verify FlutterSkillBinding.ensureInitialized() is called in main()
   • Run flutter with: --vm-service-port=50000 for consistent connections
''');
    }

    if (!client.isConnected) {
      // Connection lost - note: with multi-session, we don't clean up here
      throw Exception('''❌ Connection to Flutter app was lost.

📍 What Happened:
   • VM Service connection dropped
   • App may have crashed, restarted, or been terminated

🔧 How to Reconnect:

   Option 1: Auto-reconnect
   ───────────────────────────────────────────────
   scan_and_connect()
   → Automatically finds running Flutter apps

   Option 2: Reconnect with URI
   ───────────────────────────────────────────────
   connect_app(uri: "ws://...")
   → Use the same URI or check get_connection_status() for new URI

   Option 3: Restart App
   ───────────────────────────────────────────────
   launch_app(project_path: "...")
   → Launch a fresh instance

💡 Check Status:
   get_connection_status() → See all available running apps
''');
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
        final logs = await client.getLogs();
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
        final elements = await client.getInteractiveElements();

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
        final memoryStats = await client.getMemoryStats();
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
        final screenshot = await client.takeScreenshot();
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
