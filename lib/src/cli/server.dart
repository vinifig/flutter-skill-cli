import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:http/http.dart' as http;
import '../bridge/bridge_protocol.dart';
import '../bridge/cdp_driver.dart';
import '../bridge/web_bridge_listener.dart';
import '../discovery/bridge_discovery.dart';
import '../drivers/web_bridge_driver.dart';
import '../drivers/app_driver.dart';
import '../drivers/bridge_driver.dart';
import '../drivers/flutter_driver.dart';
import '../drivers/native_driver.dart';
import '../diagnostics/error_reporter.dart';
import 'setup.dart';

const String currentVersion = '0.8.3';

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

    String? autoUrl;
    int? cdpPort;

    // Parse flags
    for (final arg in args) {
      if (arg.startsWith('--bridge-port=')) {
        final port = int.tryParse(arg.substring('--bridge-port='.length)) ?? bridgeDefaultPort;
        await server.startBridgeListener(port);
      } else if (arg == '--bridge-port') {
        await server.startBridgeListener(bridgeDefaultPort);
      } else if (arg.startsWith('--url=')) {
        autoUrl = arg.substring('--url='.length);
      } else if (arg.startsWith('--cdp-port=')) {
        cdpPort = int.tryParse(arg.substring('--cdp-port='.length));
      } else if (arg.startsWith('--plugins-dir=')) {
        server._pluginsDir = arg.substring('--plugins-dir='.length);
      }
    }

    await server._loadPlugins();

    if (autoUrl != null) {
      server._autoConnectUrl = autoUrl;
      server._autoConnectCdpPort = cdpPort;
    }

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

  // Auto-connect CDP on startup (set via --url flag)
  String? _autoConnectUrl;
  int? _autoConnectCdpPort;

  // Plugin system
  String _pluginsDir = '${Platform.environment['HOME'] ?? '.'}/.flutter-skill/plugins';
  final List<Map<String, dynamic>> _pluginTools = [];

  // Last known connection info for auto-reconnect
  String? _lastConnectionUri;
  int? _lastConnectionPort;

  // Legacy single client support (for backward compatibility)
  AppDriver? get _client => _activeSessionId != null
      ? _clients[_activeSessionId]
      : _clients.values.isNotEmpty
          ? _clients.values.first
          : null;

  Process? _flutterProcess;

  // Recording state
  bool _isRecording = false;
  final List<Map<String, dynamic>> _recordedSteps = [];
  DateTime? _recordingStartTime;

  // Video recording state
  Process? _videoProcess;
  String? _videoPath;
  String? _videoPlatform;
  String? _videoDevicePath;

  // CDP driver for vanilla web testing
  CdpDriver? _cdpDriver;

  // Web bridge listener for browser-based SDKs
  WebBridgeListener? _webBridgeListener;

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

  /// Start the web bridge listener for browser-based SDKs.
  Future<void> startBridgeListener(int port) async {
    if (_webBridgeListener != null) return;
    final listener = WebBridgeListener();
    String? _webSessionId;
    listener.onClientConnected = (_) {
      // Delay to let WS connection stabilize (SDK sends bridge.hello, may reconnect)
      Future.delayed(const Duration(milliseconds: 2000), () async {
        if (!listener.hasClient) return; // Already disconnected
        try {
          final driver = WebBridgeDriver(listener);
          await driver.connect();
          final sessionId = _webSessionId ?? _generateSessionId();
          _webSessionId = sessionId;
          _clients[sessionId] = driver;
          _sessions[sessionId] = SessionInfo(
            id: sessionId,
            name: 'Web app (bridge listener)',
            projectPath: 'web',
            deviceId: 'web',
            port: port,
            vmServiceUri: 'ws://127.0.0.1:$port',
          );
          _activeSessionId = sessionId;
          stderr.writeln('Browser client connected — session $sessionId created');
        } catch (e) {
          stderr.writeln('Failed to initialize web bridge session: $e');
        }
      });
    };
    listener.onClientDisconnected = () {
      stderr.writeln('Browser client disconnected from bridge listener');
    };
    await listener.start(port);
    _webBridgeListener = listener;
    stderr.writeln('Bridge listener started on ws://127.0.0.1:$port');
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
        // Auto-connect CDP if --url was provided
        if (_autoConnectUrl != null) {
          final url = _autoConnectUrl!;
          _autoConnectUrl = null; // Only once
          Future(() async {
            try {
              final port = _autoConnectCdpPort ?? 9222;
              stderr.writeln('Auto-connecting CDP to $url (port $port)...');
              final result = await _executeTool('connect_cdp', {
                'url': url,
                'port': port,
                'launch_chrome': true,
              });
              stderr.writeln('CDP auto-connect: $result');
            } catch (e) {
              stderr.writeln('CDP auto-connect failed: $e');
            }
          });
        }
      } else if (method == 'notifications/initialized') {
        // No op
      } else if (method == 'tools/list') {
        _sendResult(id, {"tools": _getToolsList()});
      } else if (method == 'tools/call') {
        final name = params['name'];
        final args = params['arguments'] as Map<String, dynamic>? ?? {};
        final result = await _executeTool(name, args);
        // Recording middleware
        if (_isRecording && ['tap', 'enter_text', 'scroll', 'swipe', 'go_back', 'press_key', 'screenshot'].contains(name)) {
          _recordedSteps.add({
            'step': _recordedSteps.length + 1,
            'tool': name,
            'params': args,
            'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
            'result': result is Map ? (result['success'] ?? true) : true,
          });
        }
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
    // Determine current connection mode for smart filtering
    final hasCdp = _cdpDriver != null;
    final hasBridge = _client is BridgeDriver && _cdpDriver == null;
    final hasFlutter = _client is FlutterSkillClient && _client is! BridgeDriver;
    final hasConnection = _client != null || hasCdp;

    // CDP-only tools that don't apply to bridge/Flutter platforms
    const cdpOnlyTools = <String>{
      'connect_cdp', 'get_title', 'get_page_source', 'get_visible_text',
      'count_elements', 'is_visible', 'get_attribute', 'get_css_property',
      'get_bounding_box', 'get_cookies', 'set_cookie', 'clear_cookies',
      'get_local_storage', 'set_local_storage', 'clear_local_storage',
      'get_session_storage', 'get_console_messages', 'get_network_requests',
      'navigate', 'go_forward', 'reload', 'set_viewport', 'emulate_device',
      'generate_pdf', 'wait_for_navigation', 'wait_for_network_idle',
      'get_tabs', 'new_tab', 'close_tab', 'switch_tab', 'get_frames',
      'eval_in_frame', 'get_window_handles', 'install_dialog_handler',
      'handle_dialog', 'intercept_requests', 'clear_interceptions',
      'block_urls', 'throttle_network', 'go_offline', 'clear_browser_data',
      'accessibility_audit', 'set_geolocation', 'set_timezone',
      'set_color_scheme', 'upload_file', 'compare_screenshot',
    };

    // Flutter VM Service-only tools
    const flutterOnlyTools = <String>{
      'get_widget_tree', 'get_widget_properties', 'find_by_type',
      'hot_reload', 'hot_restart',
    };

    // Mobile-only tools
    const mobileOnlyTools = <String>{
      'native_tap', 'native_input_text', 'native_swipe', 'native_screenshot',
      'auth_biometric', 'auth_deeplink',
    };

    final allTools = <Map<String, dynamic>>[
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

      // CDP Connection
      {
        "name": "connect_cdp",
        "description": """Connect to any web page via Chrome DevTools Protocol (CDP).

No SDK injection needed — works with ANY website, React/Vue/Angular apps, or any web content.

[USE WHEN]
• Testing a web app that doesn't have flutter_skill SDK
• Testing any website (React, Vue, Angular, plain HTML)
• Automating browser interactions on arbitrary web pages

[HOW IT WORKS]
1. Launches Chrome with remote debugging (or connects to existing)
2. Navigates to the given URL
3. Connects via CDP WebSocket
4. All subsequent tool calls (inspect, tap, enter_text, screenshot, etc.) work via CDP

[AFTER CONNECTING]
Use the same tools as usual: inspect(), tap(), enter_text(), screenshot(), snapshot(), etc.
They will automatically route through the CDP connection.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {
              "type": "string",
              "description": "URL to navigate to (e.g. https://example.com)"
            },
            "port": {
              "type": "integer",
              "description":
                  "Chrome remote debugging port (default: 9222)"
            },
            "launch_chrome": {
              "type": "boolean",
              "description":
                  "Launch a new Chrome instance (default: true). Set to false to connect to already-running Chrome."
            },
          },
          "required": ["url"],
        },
      },

      // Web Bridge Listener
      {
        "name": "start_bridge_listener",
        "description": """Start a WebSocket listener for browser-based SDKs.

Browser SDKs cannot start a WebSocket server, so this starts one on the MCP
server side that browser clients connect TO. A session is auto-created when
a client connects.

After starting, point the web SDK at ws://127.0.0.1:<port>.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "port": {
              "type": "integer",
              "description": "Port to listen on (default: 18118)"
            },
          },
        },
      },
      {
        "name": "stop_bridge_listener",
        "description": "Stop the WebSocket bridge listener.",
        "inputSchema": {"type": "object", "properties": {}},
      },

      // CDP-exclusive tools (web testing superpowers)
      {"name": "eval", "description": "Execute JavaScript in the browser and return the result. Works with CDP and bridge connections.", "inputSchema": {"type": "object", "properties": {"expression": {"type": "string", "description": "JavaScript expression to evaluate"}}, "required": ["expression"]}},
      {"name": "press_key", "description": "Press a keyboard key (Enter, Tab, Escape, ArrowUp, etc.)", "inputSchema": {"type": "object", "properties": {"key": {"type": "string", "description": "Key name (Enter, Tab, Escape, Backspace, ArrowUp, ArrowDown, Space, or any character)"}, "modifiers": {"type": "array", "items": {"type": "string"}, "description": "Modifier keys: Alt, Control, Meta, Shift"}}, "required": ["key"]}},
      {"name": "hover", "description": "Hover over an element (triggers CSS :hover styles and mouseover events)", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}, "text": {"type": "string"}, "ref": {"type": "string"}}}},
      {"name": "select_option", "description": "Select an option in a <select> dropdown", "inputSchema": {"type": "object", "properties": {"key": {"type": "string", "description": "Element ID or test ID"}, "value": {"type": "string", "description": "Option value to select"}}, "required": ["key", "value"]}},
      {"name": "set_checkbox", "description": "Check or uncheck a checkbox", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}, "checked": {"type": "boolean"}}, "required": ["key"]}},
      {"name": "fill", "description": "Fill an input field (clear + set value — faster than enter_text for forms)", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}, "value": {"type": "string"}}, "required": ["key", "value"]}},
      {"name": "get_cookies", "description": "Get all browser cookies for the current page", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "set_cookie", "description": "Set a browser cookie", "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}, "value": {"type": "string"}, "domain": {"type": "string"}, "path": {"type": "string"}}, "required": ["name", "value"]}},
      {"name": "clear_cookies", "description": "Clear all browser cookies", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "get_local_storage", "description": "Get all localStorage key-value pairs", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "set_local_storage", "description": "Set a localStorage value", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}, "value": {"type": "string"}}, "required": ["key", "value"]}},
      {"name": "clear_local_storage", "description": "Clear all localStorage data", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "get_console_messages", "description": "Get browser console log messages", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "get_network_requests", "description": "Get all network requests made by the page (via Performance API)", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "set_viewport", "description": "Set browser viewport size (responsive testing)", "inputSchema": {"type": "object", "properties": {"width": {"type": "integer"}, "height": {"type": "integer"}, "device_scale_factor": {"type": "number"}}, "required": ["width", "height"]}},
      {"name": "emulate_device", "description": "Emulate a device viewport + user agent. 143+ presets: iPhone 12-16 (all sizes), SE, Pixel 5-9, Galaxy S21-S24, Z Fold/Flip, OnePlus, Xiaomi, Huawei, iPad Pro/Air/Mini, Galaxy Tab, Surface Pro, MacBook Air/Pro, Dell XPS, desktop resolutions (1080p/1440p/4K) with Chrome/Firefox/Safari/Edge UAs. Supports flexible naming: 'iPhone 14 Pro', 'iphone-14-pro', 'iphone14pro' all work. Pass empty device to list all available presets.", "inputSchema": {"type": "object", "properties": {"device": {"type": "string", "description": "Device name (e.g. 'iphone-16-pro-max', 'pixel-8', 'galaxy-s24-ultra', 'ipad-pro-11', 'macbook-pro-16', 'desktop-1080p'). Empty string lists all devices."}}, "required": ["device"]}},
      {"name": "generate_pdf", "description": "Generate a PDF of the current page", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "navigate", "description": "Navigate to a URL", "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}},
      {"name": "go_forward", "description": "Navigate forward in browser history", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "reload", "description": "Reload the current page", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "get_attribute", "description": "Get an HTML element's attribute value", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}, "attribute": {"type": "string"}}, "required": ["key", "attribute"]}},
      {"name": "get_css_property", "description": "Get computed CSS property of an element", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}, "property": {"type": "string"}}, "required": ["key", "property"]}},
      {"name": "get_bounding_box", "description": "Get element position and size", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}}, "required": ["key"]}},
      {"name": "focus", "description": "Focus an element", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}}, "required": ["key"]}},
      {"name": "blur", "description": "Remove focus from an element", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}}, "required": ["key"]}},
      {"name": "count_elements", "description": "Count elements matching a CSS selector", "inputSchema": {"type": "object", "properties": {"selector": {"type": "string"}}, "required": ["selector"]}},
      {"name": "is_visible", "description": "Check if an element is visible on page", "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}}, "required": ["key"]}},
      {"name": "get_page_source", "description": "Get the HTML source of the current page with optional cleaning", "inputSchema": {"type": "object", "properties": {"selector": {"type": "string", "description": "CSS selector to get HTML for a specific element only"}, "remove_scripts": {"type": "boolean", "description": "Strip <script> tags"}, "remove_styles": {"type": "boolean", "description": "Strip <style> tags"}, "remove_comments": {"type": "boolean", "description": "Strip HTML comments"}, "remove_meta": {"type": "boolean", "description": "Strip <meta> tags"}, "minify": {"type": "boolean", "description": "Collapse whitespace"}, "clean_html": {"type": "boolean", "description": "Convenience: removes scripts, styles, comments, and meta tags"}}}},
      {"name": "get_visible_text", "description": "Get only visible text content from the page (skips display:none, visibility:hidden elements). CDP only.", "inputSchema": {"type": "object", "properties": {"selector": {"type": "string", "description": "CSS selector to scope text extraction"}}}},
      {"name": "get_window_handles", "description": "Get all browser window/tab handles", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "install_dialog_handler", "description": "Install auto-handler for JS dialogs (alert/confirm/prompt)", "inputSchema": {"type": "object", "properties": {"auto_accept": {"type": "boolean", "description": "Auto-accept dialogs (default: true)"}}}},
      {"name": "wait_for_navigation", "description": "Wait for page navigation to complete", "inputSchema": {"type": "object", "properties": {"timeout_ms": {"type": "integer", "description": "Timeout in ms (default: 30000)"}}}},
      {"name": "get_title", "description": "Get the page title", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "set_geolocation", "description": "Override browser geolocation", "inputSchema": {"type": "object", "properties": {"latitude": {"type": "number"}, "longitude": {"type": "number"}}, "required": ["latitude", "longitude"]}},
      {"name": "set_color_scheme", "description": "Set dark/light mode preference", "inputSchema": {"type": "object", "properties": {"scheme": {"type": "string", "enum": ["dark", "light"]}}, "required": ["scheme"]}},
      {"name": "block_urls", "description": "Block network requests matching URL patterns (ads, trackers, etc.)", "inputSchema": {"type": "object", "properties": {"patterns": {"type": "array", "items": {"type": "string"}}}, "required": ["patterns"]}},
      {"name": "throttle_network", "description": "Simulate slow network (3G, offline, etc.)", "inputSchema": {"type": "object", "properties": {"latency_ms": {"type": "integer"}, "download_kbps": {"type": "integer"}, "upload_kbps": {"type": "integer"}}}},
      {"name": "go_offline", "description": "Simulate offline mode (no network)", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "clear_browser_data", "description": "Clear all browser data (cookies, cache, localStorage, sessionStorage)", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "upload_file", "description": "Upload file(s) to a file input element", "inputSchema": {"type": "object", "properties": {"selector": {"type": "string", "description": "CSS selector for input[type=file]"}, "files": {"type": "array", "items": {"type": "string"}, "description": "File paths to upload"}}, "required": ["selector", "files"]}},
      {"name": "handle_dialog", "description": "Accept or dismiss browser dialog (alert/confirm/prompt)", "inputSchema": {"type": "object", "properties": {"accept": {"type": "boolean"}, "prompt_text": {"type": "string"}}, "required": ["accept"]}},
      {"name": "get_frames", "description": "List all iframes on the page", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "eval_in_frame", "description": "Execute JavaScript inside a specific iframe", "inputSchema": {"type": "object", "properties": {"frame_id": {"type": "string"}, "expression": {"type": "string"}}, "required": ["frame_id", "expression"]}},
      {"name": "get_tabs", "description": "List all open browser tabs", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "new_tab", "description": "Open a new browser tab with a URL", "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}},
      {"name": "close_tab", "description": "Close a browser tab", "inputSchema": {"type": "object", "properties": {"target_id": {"type": "string"}}, "required": ["target_id"]}},
      {"name": "switch_tab", "description": "Switch to a different browser tab", "inputSchema": {"type": "object", "properties": {"target_id": {"type": "string"}}, "required": ["target_id"]}},
      {"name": "intercept_requests", "description": "Mock/intercept network requests matching a URL pattern (return custom responses)", "inputSchema": {"type": "object", "properties": {"url_pattern": {"type": "string"}, "status_code": {"type": "integer"}, "body": {"type": "string"}, "headers": {"type": "object"}}, "required": ["url_pattern"]}},
      {"name": "clear_interceptions", "description": "Remove all network request interceptions", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "accessibility_audit", "description": "Run accessibility audit (WCAG checks: missing alt, labels, heading order, contrast, lang, viewport)", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "compare_screenshot", "description": "Visual regression test — compare current page to a baseline screenshot", "inputSchema": {"type": "object", "properties": {"baseline_path": {"type": "string", "description": "Path to baseline PNG image"}}, "required": ["baseline_path"]}},
      {"name": "wait_for_network_idle", "description": "Wait until all network requests complete (no pending fetch/XHR)", "inputSchema": {"type": "object", "properties": {"timeout_ms": {"type": "integer"}, "idle_ms": {"type": "integer"}}}},
      {"name": "get_session_storage", "description": "Get all sessionStorage key-value pairs", "inputSchema": {"type": "object", "properties": {}}},
      {"name": "type_text", "description": "Type text character by character (realistic typing simulation)", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
      {"name": "set_timezone", "description": "Override browser timezone", "inputSchema": {"type": "object", "properties": {"timezone": {"type": "string", "description": "IANA timezone (e.g. America/New_York)"}}, "required": ["timezone"]}},

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
        "name": "inspect_interactive",
        "description": """⚡ ENHANCED UI DISCOVERY TOOL ⚡

[TRIGGER KEYWORDS]
interactive elements | structured inspect | enhanced inspect | ui elements with actions | elements with selectors | actionable elements | smart inspect

[PRIMARY PURPOSE]
Discover interactive UI elements with enhanced data structure including:
• Available actions for each element (["tap", "long_press", "enter_text"])
• Reliable selectors for targeting elements
• Current state information (enabled, value, visible)
• Filtered results showing only actionable elements

[USE WHEN]
• You need structured element data for automation
• Building element interaction strategies
• Need reliable selectors instead of coordinates
• Want to see only actionable elements (filter out text/images)

[OUTPUT FORMAT]
Returns structured data:
{
  "elements": [
    {
      "type": "ElevatedButton", 
      "text": "Submit",
      "selector": {"by": "text", "value": "Submit"},
      "actions": ["tap", "long_press"],
      "bounds": {"x": 100, "y": 200, "width": 120, "height": 48},
      "enabled": true,
      "visible": true
    },
    {
      "type": "TextField",
      "label": "Email",
      "selector": {"by": "key", "value": "email_field"},
      "actions": ["tap", "enter_text"],
      "currentValue": "",
      "enabled": true,
      "visible": true
    }
  ],
  "summary": "Found 5 interactive elements: 2 buttons, 2 text fields, 1 switch"
}

[ADVANTAGES OVER inspect()]
• Structured element data with actions array
• Reliable selectors for each element  
• State information (enabled, current value)
• Only returns interactive elements (no static text/images)
• Better for automated workflows

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
        "name": "snapshot",
        "description": """📸 TEXT-BASED PAGE SNAPSHOT (Token-Efficient)

Returns a compact text representation of the current screen — like an accessibility tree.
This is MUCH more token-efficient than screenshot (typically 500 tokens vs 10,000+).

Use this INSTEAD of screenshot() when you need to understand what's on screen.
Only use screenshot() when you need actual pixel-level visual verification.

Output format:
```
Screen: LoginPage (375x812)
├── [img] App Logo (187,50 150x150)
├── [text] "Welcome Back" (100,220)
├── [input:Email] "" (20,280 335x48) ← ref
├── [input:Password] "" (20,340 335x48) ← ref
├── [button:Login] "Login" (20,410 335x48) enabled ← ref
├── [link:ForgotPassword] "Forgot Password?" (120,470) ← ref
└── [button:SignUp] "Sign Up" (120,520) enabled ← ref
```

Elements with [ref] can be targeted: tap(ref: "button:Login"), enter_text(ref: "input:Email", text: "...")
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
1. By semantic ref ID: tap(ref: "button:Login")  // From inspect_interactive() - RECOMMENDED
2. By Widget key: tap(key: "submit_button")
3. By visible text: tap(text: "Submit")
4. By coordinates: tap(x: 100, y: 200)  // Use center coordinates from inspect()

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
            "ref": {"type": "string", "description": "Semantic ref ID from inspect_interactive (RECOMMENDED)"},
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
Option 1 (RECOMMENDED): Call inspect_interactive() to find TextField refs, then enter_text(ref: "input:Email", text: "value").
Option 2: Call inspect() to find TextField keys, then enter_text(key: "field_key", text: "value").
Option 3: Tap a TextField first, then enter_text(text: "value") without key/ref - enters into focused field.
""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "ref": {
              "type": "string",
              "description": "Semantic ref ID from inspect_interactive (RECOMMENDED)"
            },
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
      {
        "name": "assert_batch",
        "description": "Run multiple assertions in a single call. Returns all results (does not fail-fast).",
        "inputSchema": {
          "type": "object",
          "properties": {
            "assertions": {
              "type": "array",
              "description": "List of assertions to run",
              "items": {
                "type": "object",
                "properties": {
                  "type": {"type": "string", "enum": ["visible", "not_visible", "text", "element_count"], "description": "Assertion type"},
                  "key": {"type": "string", "description": "Element key"},
                  "text": {"type": "string", "description": "Text to find (for visible/not_visible) or expected text (for text assertion)"},
                  "expected": {"type": "string", "description": "Expected value for text assertion"},
                  "count": {"type": "integer", "description": "Expected count for element_count assertion"},
                },
                "required": ["type"],
              },
            },
          },
          "required": ["assertions"],
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

      // Auth Tools
      {
        "name": "auth_inject_session",
        "description": "Inject auth token into app storage (cookie, localStorage, or shared_preferences).",
        "inputSchema": {
          "type": "object",
          "properties": {
            "token": {"type": "string", "description": "Auth token to inject"},
            "key": {"type": "string", "description": "Storage key (default: auth_token)"},
            "storage_type": {"type": "string", "enum": ["cookie", "local_storage", "shared_preferences"], "description": "Storage type"},
          },
          "required": ["token"],
        },
      },
      {
        "name": "auth_biometric",
        "description": "Simulate biometric authentication on iOS simulator or Android emulator.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "action": {"type": "string", "enum": ["enroll", "match", "fail"], "description": "Biometric action"},
          },
          "required": ["action"],
        },
      },
      {
        "name": "auth_otp",
        "description": "Generate TOTP code from secret, or read OTP from simulator clipboard.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "secret": {"type": "string", "description": "TOTP secret (base32). If omitted, reads clipboard."},
            "digits": {"type": "integer", "description": "OTP digits (default: 6)"},
            "period": {"type": "integer", "description": "TOTP period in seconds (default: 30)"},
          },
        },
      },
      {
        "name": "auth_deeplink",
        "description": "Open a deep link URL on the simulator/emulator.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": {"type": "string", "description": "Deep link URL to open"},
            "device": {"type": "string", "description": "Device identifier"},
          },
          "required": ["url"],
        },
      },

      // Recording & Code Generation
      {
        "name": "record_start",
        "description": "Start recording tool calls for test code generation.",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "record_stop",
        "description": "Stop recording and return recorded steps.",
        "inputSchema": {"type": "object", "properties": {}},
      },
      {
        "name": "record_export",
        "description": "Export recorded steps as test code in various formats.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "format": {"type": "string", "enum": ["jest", "pytest", "dart_test", "playwright", "cypress", "selenium", "xcuitest", "espresso", "json"], "description": "Export format: jest (JS), pytest (Python), dart_test (Dart), playwright (JS), cypress (JS), selenium (Python), xcuitest (Swift), espresso (Kotlin), json (raw)"},
          },
          "required": ["format"],
        },
      },

      // Video Recording
      {
        "name": "video_start",
        "description": "Start screen recording on simulator/emulator.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "device": {"type": "string", "description": "Device identifier"},
            "path": {"type": "string", "description": "Output file path"},
          },
        },
      },
      {
        "name": "video_stop",
        "description": "Stop screen recording and return the video file path.",
        "inputSchema": {"type": "object", "properties": {}},
      },

      // AI Visual Verification
      {
        "name": "visual_verify",
        "description": """Take a screenshot AND text snapshot for AI visual verification.

Returns both a screenshot file and structured text snapshot so the calling AI can verify
the UI matches the expected description. Optionally checks for specific elements.

[USE WHEN]
• Verifying UI looks correct after a series of actions
• Checking that expected elements are present on screen
• Visual QA of a screen against a description

[RETURNS]
Combined result with screenshot path, text snapshot, element matching results, and a hint
for the AI to compare against the provided description.""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "description": {
              "type": "string",
              "description": "What the UI should look like (e.g., 'login form with email and password fields')"
            },
            "check_elements": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Specific elements that should be visible (matched against snapshot refs and text)"
            },
            "quality": {
              "type": "number",
              "description": "Screenshot quality 0-1 (default 0.5)"
            },
          },
        },
      },
      {
        "name": "visual_diff",
        "description": """Compare current screen against a baseline screenshot.

Takes a new screenshot and returns both the current and baseline paths so the calling AI
can visually compare them. Also returns text snapshots for structural comparison.

[USE WHEN]
• Visual regression testing
• Comparing before/after states
• Verifying no unintended UI changes""",
        "inputSchema": {
          "type": "object",
          "properties": {
            "baseline_path": {
              "type": "string",
              "description": "Path to baseline screenshot file"
            },
            "description": {
              "type": "string",
              "description": "What to focus on when comparing (optional)"
            },
            "quality": {
              "type": "number",
              "description": "Screenshot quality 0-1 (default 0.5)"
            },
          },
          "required": ["baseline_path"],
        },
      },

      // Parallel Multi-Device
      {
        "name": "parallel_snapshot",
        "description": "Take snapshots from multiple sessions in parallel.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_ids": {"type": "array", "items": {"type": "string"}, "description": "Session IDs (default: all)"},
          },
        },
      },
      {
        "name": "parallel_tap",
        "description": "Execute tap on multiple sessions in parallel.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "ref": {"type": "string", "description": "Element ref to tap"},
            "key": {"type": "string", "description": "Element key to tap"},
            "text": {"type": "string", "description": "Element text to tap"},
            "session_ids": {"type": "array", "items": {"type": "string"}, "description": "Session IDs (default: all)"},
          },
        },
      },

      // Cross-Platform Test Orchestration
      {
        "name": "multi_platform_test",
        "description": "Run the same test steps across all connected platforms simultaneously. Great for cross-platform verification.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "actions": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "tool": {"type": "string"},
                  "args": {"type": "object"},
                },
              },
              "description": "Sequence of tool calls to execute on each platform"
            },
            "session_ids": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Specific sessions to test (default: all connected)"
            },
            "stop_on_failure": {
              "type": "boolean",
              "description": "Stop all platforms on first failure (default: false)"
            },
          },
          "required": ["actions"],
        },
      },
      {
        "name": "compare_platforms",
        "description": "Take snapshots from all connected platforms and compare element presence. Identifies cross-platform inconsistencies.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session_ids": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Specific sessions to compare (default: all connected)"
            },
          },
        },
      },
      // === Plugin Tools ===
      {
        "name": "list_plugins",
        "description": "List all loaded custom plugin tools with their descriptions.",
        "inputSchema": {"type": "object", "properties": {}},
      },
      // === Test Report Generation ===
      {
        "name": "generate_report",
        "description": "Generate a test report from recorded test steps and assertions. Supports HTML, JSON, and Markdown formats.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "format": {"type": "string", "enum": ["html", "json", "markdown"], "description": "Report format (default: html)"},
            "title": {"type": "string", "description": "Report title"},
            "output_path": {"type": "string", "description": "Where to save the report file"},
            "include_screenshots": {"type": "boolean", "description": "Embed screenshots in report (default: true)"},
          },
        },
      },
    ];

    // Append plugin-defined tools
    for (final plugin in _pluginTools) {
      allTools.add({
        "name": plugin['name'],
        "description": plugin['description'] ?? 'Custom plugin tool',
        "inputSchema": {"type": "object", "properties": {}},
      });
    }

    // Smart filtering: when connected, only return relevant tools
    if (!hasConnection) return allTools; // No connection = show all for discovery

    return allTools.where((tool) {
      final name = tool['name'] as String;
      if (hasCdp) {
        // CDP mode: hide Flutter-only and mobile-only tools
        if (flutterOnlyTools.contains(name)) return false;
        if (mobileOnlyTools.contains(name)) return false;
      } else if (hasBridge) {
        // Bridge mode: hide CDP-only and Flutter-only tools
        if (cdpOnlyTools.contains(name)) return false;
        if (flutterOnlyTools.contains(name)) return false;
      } else if (hasFlutter) {
        // Flutter VM Service: hide CDP-only tools
        if (cdpOnlyTools.contains(name)) return false;
      }
      return true;
    }).toList();
  }

  Future<Map<String, dynamic>> _executeBatchAssertions(Map<String, dynamic> args, AppDriver client) async {
    final assertions = (args['assertions'] as List<dynamic>?) ?? [];
    final results = <Map<String, dynamic>>[];
    int passed = 0, failed = 0;
    for (final assertion in assertions) {
      final a = assertion as Map<String, dynamic>;
      final aType = a['type'] as String;
      try {
        final toolName = aType == 'visible' ? 'assert_visible'
            : aType == 'not_visible' ? 'assert_not_visible'
            : aType == 'text' ? 'assert_text'
            : aType == 'element_count' ? 'assert_element_count'
            : aType;
        final toolArgs = <String, dynamic>{
          if (a['key'] != null) 'key': a['key'],
          if (a['text'] != null) 'text': a['text'],
          if (a['expected'] != null) 'expected': a['expected'],
          if (a['count'] != null) 'expected_count': a['count'],
        };
        final result = await _executeToolInner(toolName, toolArgs);
        final success = result is Map && result['success'] != false;
        if (success) passed++; else failed++;
        results.add({'type': aType, 'success': success, 'result': result});
      } catch (e) {
        failed++;
        results.add({'type': aType, 'success': false, 'error': e.toString()});
      }
    }
    return {'success': failed == 0, 'total': assertions.length, 'passed': passed, 'failed': failed, 'results': results};
  }

  Future<Map<String, dynamic>> _executeVisualVerify(Map<String, dynamic> args, AppDriver client) async {
    final quality = (args['quality'] as num?)?.toDouble() ?? 0.5;
    final desc = args['description'] as String? ?? '';
    final checkElements = (args['check_elements'] as List?)?.cast<String>() ?? [];

    final imageBase64 = await client.takeScreenshot(quality: quality, maxWidth: 800);
    String? screenshotPath;
    if (imageBase64 != null) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File('${Directory.systemTemp.path}/flutter_skill_verify_$ts.png');
      await file.writeAsBytes(base64.decode(imageBase64));
      screenshotPath = file.path;
    }

    String snapshotText = '';
    List<String> found = [], missing = [];
    int elementCount = 0;
    try {
      final structured = await client.getInteractiveElementsStructured();
      final els = structured['elements'] as List<dynamic>? ?? [];
      elementCount = els.length;
      final buf = StringBuffer();
      for (final el in els) {
        if (el is Map<String, dynamic>) {
          buf.writeln('[${el['ref'] ?? ''}] "${el['text'] ?? el['label'] ?? ''}"');
        }
      }
      snapshotText = buf.toString();
      if (checkElements.isNotEmpty) {
        final lower = snapshotText.toLowerCase();
        for (final c in checkElements) {
          (lower.contains(c.toLowerCase()) ? found : missing).add(c);
        }
      }
    } catch (e) {
      snapshotText = 'Error: $e';
    }
    return {
      'success': true, 'screenshot': screenshotPath, 'snapshot': snapshotText,
      'elements_found': found, 'elements_missing': missing, 'element_count': elementCount,
      'description_to_verify': desc,
      'hint': 'Compare the screenshot and snapshot against the description.',
    };
  }

  Future<Map<String, dynamic>> _executeVisualDiff(Map<String, dynamic> args, AppDriver client) async {
    final quality = (args['quality'] as num?)?.toDouble() ?? 0.5;
    final baselinePath = args['baseline_path'] as String? ?? '';
    if (baselinePath.isEmpty || !await File(baselinePath).exists()) {
      return {'success': false, 'error': 'Baseline file not found: $baselinePath'};
    }
    final imageBase64 = await client.takeScreenshot(quality: quality, maxWidth: 800);
    String? currentPath;
    if (imageBase64 != null) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File('${Directory.systemTemp.path}/flutter_skill_diff_$ts.png');
      await file.writeAsBytes(base64.decode(imageBase64));
      currentPath = file.path;
    }
    return {
      'success': true, 'baseline_path': baselinePath, 'current_screenshot': currentPath,
      'hint': 'Compare baseline with current screenshot for visual differences.',
    };
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

  /// Load plugin tools from the plugins directory
  Future<void> _loadPlugins() async {
    final dir = Directory(_pluginsDir);
    if (!await dir.exists()) {
      stderr.writeln('Plugins directory not found: $_pluginsDir (skipping)');
      return;
    }
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final plugin = jsonDecode(content) as Map<String, dynamic>;
          final name = plugin['name'] as String?;
          final description = plugin['description'] as String? ?? 'Custom plugin';
          final steps = (plugin['steps'] as List<dynamic>?) ?? [];
          if (name == null || steps.isEmpty) continue;
          _pluginTools.add({
            'name': name,
            'description': description,
            'steps': steps,
            'source': entity.path,
          });
          stderr.writeln('Loaded plugin: $name (${steps.length} steps)');
        } catch (e) {
          stderr.writeln('Failed to load plugin ${entity.path}: $e');
        }
      }
    }
    if (_pluginTools.isNotEmpty) {
      stderr.writeln('Loaded ${_pluginTools.length} plugin(s)');
    }
  }

  /// Execute a plugin by running its steps sequentially
  Future<dynamic> _executePlugin(Map<String, dynamic> plugin, Map<String, dynamic> args) async {
    final steps = (plugin['steps'] as List<dynamic>);
    final results = <Map<String, dynamic>>[];
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i] as Map<String, dynamic>;
      final toolName = step['tool'] as String;
      final toolArgs = Map<String, dynamic>.from((step['args'] as Map<String, dynamic>?) ?? {});
      // Allow overriding step args from the call args
      toolArgs.addAll(args);
      final stopwatch = Stopwatch()..start();
      try {
        final result = await _executeToolInner(toolName, toolArgs);
        stopwatch.stop();
        results.add({
          'step': i + 1,
          'tool': toolName,
          'success': true,
          'result': result,
          'duration_ms': stopwatch.elapsedMilliseconds,
        });
      } catch (e) {
        stopwatch.stop();
        results.add({
          'step': i + 1,
          'tool': toolName,
          'success': false,
          'error': e.toString(),
          'duration_ms': stopwatch.elapsedMilliseconds,
        });
        break;
      }
    }
    final passed = results.where((r) => r['success'] == true).length;
    return {
      'plugin': plugin['name'],
      'steps_total': steps.length,
      'steps_executed': results.length,
      'steps_passed': passed,
      'success': passed == results.length,
      'results': results,
    };
  }

  /// Generate test report from recorded steps
  Future<dynamic> _generateReport(Map<String, dynamic> args) async {
    final format = (args['format'] as String?) ?? 'html';
    final title = (args['title'] as String?) ?? 'Flutter Skill Test Report';
    final outputPath = args['output_path'] as String?;
    // ignore: unused_local_variable
    final includeScreenshots = (args['include_screenshots'] as bool?) ?? true;
    final now = DateTime.now();

    final steps = _recordedSteps;
    final passed = steps.where((s) => s['result'] == true).length;
    final failed = steps.length - passed;
    final passRate = steps.isEmpty ? 100.0 : (passed / steps.length * 100);

    if (format == 'json') {
      final report = {
        'title': title,
        'generated_at': now.toIso8601String(),
        'version': currentVersion,
        'summary': {'total': steps.length, 'passed': passed, 'failed': failed, 'pass_rate': passRate},
        'steps': steps,
      };
      if (outputPath != null) {
        await File(outputPath).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        return {'format': 'json', 'output_path': outputPath, 'step_count': steps.length};
      }
      return report;
    }

    if (format == 'markdown') {
      final buf = StringBuffer();
      buf.writeln('# $title');
      buf.writeln('');
      buf.writeln('**Generated:** ${now.toIso8601String()}  ');
      buf.writeln('**Version:** flutter-skill v$currentVersion  ');
      buf.writeln('**Summary:** $passed passed, $failed failed (${passRate.toStringAsFixed(1)}%)');
      buf.writeln('');
      buf.writeln('| # | Tool | Args | Result | Duration |');
      buf.writeln('|---|------|------|--------|----------|');
      for (final step in steps) {
        final stepNum = step['step'] ?? '-';
        final tool = step['tool'] ?? '';
        final argsStr = jsonEncode(step['params'] ?? {});
        final result = step['result'] == true ? '✅ Pass' : '❌ Fail';
        final dur = step['duration_ms'] ?? '-';
        buf.writeln('| $stepNum | $tool | `$argsStr` | $result | ${dur}ms |');
      }
      final md = buf.toString();
      if (outputPath != null) {
        await File(outputPath).writeAsString(md);
        return {'format': 'markdown', 'output_path': outputPath, 'step_count': steps.length};
      }
      return {'format': 'markdown', 'content': md, 'step_count': steps.length};
    }

    // HTML format
    final stepsHtml = StringBuffer();
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final rowClass = i % 2 == 0 ? 'even' : 'odd';
      final resultClass = step['result'] == true ? 'pass' : 'fail';
      final resultText = step['result'] == true ? '✅ Pass' : '❌ Fail';
      final argsStr = _htmlEscape(jsonEncode(step['params'] ?? {}));
      stepsHtml.writeln('<tr class="$rowClass">');
      stepsHtml.writeln('  <td>${step['step'] ?? i + 1}</td>');
      stepsHtml.writeln('  <td><code>${_htmlEscape(step['tool'] ?? '')}</code></td>');
      stepsHtml.writeln('  <td><code>$argsStr</code></td>');
      stepsHtml.writeln('  <td class="$resultClass">$resultText</td>');
      stepsHtml.writeln('  <td>${step['duration_ms'] ?? '-'}ms</td>');
      stepsHtml.writeln('</tr>');
    }

    final html = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${_htmlEscape(title)}</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f7fa; color: #333; }
  .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 32px 40px; }
  .header h1 { font-size: 28px; margin-bottom: 8px; }
  .header .meta { opacity: 0.85; font-size: 14px; }
  .summary { display: flex; gap: 24px; padding: 24px 40px; background: white; border-bottom: 1px solid #e2e8f0; }
  .summary .stat { text-align: center; }
  .summary .stat .value { font-size: 32px; font-weight: 700; }
  .summary .stat .label { font-size: 12px; text-transform: uppercase; color: #718096; margin-top: 4px; }
  .stat.passed .value { color: #38a169; }
  .stat.failed .value { color: #e53e3e; }
  .stat.rate .value { color: #667eea; }
  .content { padding: 24px 40px; }
  table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  th { background: #edf2f7; padding: 12px 16px; text-align: left; font-size: 13px; text-transform: uppercase; color: #4a5568; border-bottom: 2px solid #e2e8f0; }
  td { padding: 10px 16px; border-bottom: 1px solid #edf2f7; font-size: 14px; }
  tr.odd { background: #f7fafc; }
  tr.even { background: white; }
  td.pass { color: #38a169; font-weight: 600; }
  td.fail { color: #e53e3e; font-weight: 600; }
  code { background: #edf2f7; padding: 2px 6px; border-radius: 4px; font-size: 12px; word-break: break-all; }
  .footer { padding: 24px 40px; text-align: center; color: #a0aec0; font-size: 13px; }
  .screenshots img { max-width: 200px; cursor: pointer; border-radius: 4px; margin: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.12); transition: transform 0.2s; }
  .screenshots img:hover { transform: scale(1.05); }
  .screenshots img.expanded { max-width: 100%; }
</style>
<script>
function toggleImg(el) { el.classList.toggle('expanded'); }
</script>
</head>
<body>
<div class="header">
  <h1>${_htmlEscape(title)}</h1>
  <div class="meta">${now.toIso8601String()} &bull; flutter-skill v$currentVersion</div>
</div>
<div class="summary">
  <div class="stat"><div class="value">${steps.length}</div><div class="label">Total Steps</div></div>
  <div class="stat passed"><div class="value">$passed</div><div class="label">Passed</div></div>
  <div class="stat failed"><div class="value">$failed</div><div class="label">Failed</div></div>
  <div class="stat rate"><div class="value">${passRate.toStringAsFixed(1)}%</div><div class="label">Pass Rate</div></div>
</div>
<div class="content">
  <table>
    <thead><tr><th>#</th><th>Tool</th><th>Args</th><th>Result</th><th>Duration</th></tr></thead>
    <tbody>$stepsHtml</tbody>
  </table>
</div>
<div class="footer">Generated by flutter-skill v$currentVersion</div>
</body>
</html>''';

    if (outputPath != null) {
      await File(outputPath).writeAsString(html);
      return {'format': 'html', 'output_path': outputPath, 'step_count': steps.length};
    }
    return {'format': 'html', 'content': html, 'step_count': steps.length};
  }

  String _htmlEscape(String text) {
    return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  }

  /// Check if an error is retryable (transient connection/timeout issues)
  bool _isRetryableError(dynamic error) {
    final msg = error.toString().toLowerCase();
    // NOT retryable
    if (msg.contains('unknown tool')) return false;
    if (msg.contains('required') && msg.contains('parameter')) return false;
    if (msg.contains('element not found')) return false;
    if (msg.contains('is required')) return false;
    // Retryable
    if (msg.contains('websocket')) return true;
    if (msg.contains('connection closed')) return true;
    if (msg.contains('connection reset')) return true;
    if (msg.contains('not connected')) return true;
    if (msg.contains('connection lost')) return true;
    if (msg.contains('timed out') || msg.contains('timeout')) return true;
    if (msg.contains('socket') && (msg.contains('closed') || msg.contains('error'))) return true;
    return false;
  }

  /// Attempt auto-reconnect using last known connection info
  Future<bool> _attemptAutoReconnect() async {
    if (_lastConnectionUri != null) {
      stderr.writeln('Attempting auto-reconnect to $_lastConnectionUri (port: $_lastConnectionPort)...');
      try {
        final client = _clients[_activeSessionId];
        if (client is BridgeDriver) {
          await client.connect();
          stderr.writeln('Auto-reconnect successful');
          return true;
        }
      } catch (e) {
        stderr.writeln('Auto-reconnect failed: $e');
      }
    }
    if (_cdpDriver != null && !_cdpDriver!.isConnected) {
      stderr.writeln('CDP connection lost, attempting reconnect...');
      try {
        await _cdpDriver!.connect();
        stderr.writeln('CDP auto-reconnect successful');
        return true;
      } catch (e) {
        stderr.writeln('CDP auto-reconnect failed: $e');
      }
    }
    return false;
  }

  Future<dynamic> _executeTool(String name, Map<String, dynamic> args) async {
    const maxRetries = 2;
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final result = await _executeToolInner(name, args);
        return result;
      } catch (e) {
        if (attempt < maxRetries && _isRetryableError(e)) {
          stderr.writeln('Retryable error on attempt ${attempt + 1}: $e');
          // Try auto-reconnect on connection errors
          final msg = e.toString().toLowerCase();
          if (msg.contains('not connected') || msg.contains('connection lost') || msg.contains('connection closed')) {
            await _attemptAutoReconnect();
          }
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          continue;
        }
        rethrow;
      }
    }
    // Unreachable, but satisfies analyzer
    throw StateError('Retry loop exited unexpectedly');
  }

  Future<dynamic> _executeToolInner(String name, Map<String, dynamic> args) async {
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

    if (name == 'connect_cdp') {
      final url = args['url'] as String;
      final port = args['port'] as int? ?? 9222;
      final launchChrome = args['launch_chrome'] ?? true;

      // Disconnect existing CDP connection if any
      if (_cdpDriver != null) {
        await _cdpDriver!.disconnect();
        _cdpDriver = null;
      }

      try {
        final driver = CdpDriver(url: url, port: port, launchChrome: launchChrome);
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
          "message": "Connected to $url via CDP",
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
            "If Chrome is already running, close it or use launch_chrome: false",
            "Try: connect_cdp(url: '$url', port: $port, launch_chrome: false)",
            "Start Chrome manually with: google-chrome --remote-debugging-port=$port",
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
      if (client is CdpDriver) {
        return {"success": true, "enabled": false, "message": "No-op for CDP"};
      }
      if (client is BridgeDriver) {
        final enabled = args['enabled'] ?? true;
        final style = args['style'] ?? 'standard';
        return await client.callMethod('enable_test_indicators', {'enabled': enabled, 'style': style});
      }
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
      if (client is CdpDriver) {
        return {"enabled": false, "message": "No-op for CDP"};
      }
      if (client is BridgeDriver) {
        return await client.callMethod('get_indicator_status');
      }
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
      final result = await driver.tap(x, y).timeout(
        const Duration(seconds: 15),
        onTimeout: () => NativeResult(success: false, message: 'native_tap timed out (15s) — check macOS Accessibility permissions'),
      );
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
      final result = await driver.inputText(text).timeout(
        const Duration(seconds: 15),
        onTimeout: () => NativeResult(success: false, message: 'native_input_text timed out (15s) — check macOS Accessibility permissions'),
      );
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
          await driver.swipe(startX, startY, endX, endY, durationMs: duration).timeout(
        const Duration(seconds: 15),
        onTimeout: () => NativeResult(success: false, message: 'native_swipe timed out (15s) — check macOS Accessibility permissions'),
      );
      return result.toJson();
    }

    // Auth tools (system commands, no bridge connection required)
    if (name == 'auth_biometric') {
      final action = args['action'] as String? ?? '';
      if (action.isEmpty) return {"success": false, "error": "Missing required parameter: action (enroll|match|fail)"};
      final platform = await _detectSimulatorPlatform();
      String command;
      if (platform == 'ios') {
        // iOS biometric uses notifyutil via simctl spawn
        switch (action) {
          case 'enroll':
            command = 'xcrun simctl spawn booted notifyutil -s com.apple.BiometricKit.enrollmentChanged 1';
            break;
          case 'match':
            command = 'xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit.pearl.match';
            break;
          case 'fail':
            command = 'xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit.pearl.nomatch';
            break;
          default:
            return {"success": false, "error": "Invalid action: $action"};
        }
      } else {
        switch (action) {
          case 'enroll':
          case 'match':
            command = '${_findAdb()} -s emulator-5554 emu finger touch 1';
            break;
          case 'fail':
            command = '${_findAdb()} -s emulator-5554 emu finger touch 0';
            break;
          default:
            return {"success": false, "error": "Invalid action: $action"};
        }
      }
      try {
        final result = await Process.run('sh', ['-c', command]);
        return {"success": result.exitCode == 0, "platform": platform, "action": action};
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    if (name == 'auth_otp') {
      final secret = args['secret'] as String?;
      if (secret != null) {
        final digits = args['digits'] as int? ?? 6;
        final period = args['period'] as int? ?? 30;
        final code = _generateTotp(secret, digits, period);
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final validFor = period - (now % period);
        return {"code": code, "valid_for_seconds": validFor};
      }
      // Read clipboard
      final platform = await _detectSimulatorPlatform();
      try {
        if (platform == 'ios') {
          final result = await Process.run('xcrun', ['simctl', 'pbpaste', 'booted']);
          return {"clipboard": result.stdout.toString().trim(), "platform": "ios"};
        } else {
          final result = await Process.run(_findAdb(), ['shell', 'service', 'call', 'clipboard', '1']);
          return {"clipboard": result.stdout.toString().trim(), "platform": "android"};
        }
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    if (name == 'auth_deeplink') {
      final url = args['url'] as String;
      final platform = await _detectSimulatorPlatform();
      try {
        if (platform == 'web') {
          // For web/electron/tauri: navigate via eval
          final client = _getClient(args);
          if (client is BridgeDriver) {
            try {
              await client.callMethod('eval', {'expression': "window.location.href='$url'"});
              return {"success": true, "url": url, "platform": platform, "method": "eval"};
            } catch (_) {}
          }
          return {"success": false, "url": url, "platform": platform, "note": "Cannot open deep link on web platform without eval support"};
        }
        ProcessResult result;
        if (platform == 'ios') {
          result = await Process.run('xcrun', ['simctl', 'openurl', 'booted', url]);
        } else {
          result = await Process.run(_findAdb(), ['shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', url]);
        }
        return {"success": result.exitCode == 0, "url": url, "platform": platform};
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    // Recording tools
    if (name == 'record_start') {
      _isRecording = true;
      _recordedSteps.clear();
      _recordingStartTime = DateTime.now();
      return {"recording": true, "message": "Recording started"};
    }

    if (name == 'record_stop') {
      _isRecording = false;
      final duration = _recordingStartTime != null
          ? DateTime.now().difference(_recordingStartTime!).inMilliseconds
          : 0;
      return {"steps": _recordedSteps, "duration_ms": duration, "step_count": _recordedSteps.length};
    }

    if (name == 'record_export') {
      final format = args['format'] as String;
      String code;
      switch (format) {
        case 'json':
          code = jsonEncode(_recordedSteps);
          break;
        case 'jest':
          code = _exportJest();
          break;
        case 'pytest':
          code = _exportPytest();
          break;
        case 'dart_test':
          code = _exportDartTest();
          break;
        case 'playwright':
          code = _exportPlaywright();
          break;
        case 'cypress':
          code = _exportCypress();
          break;
        case 'selenium':
          code = _exportSelenium();
          break;
        case 'xcuitest':
          code = _exportXCUITest();
          break;
        case 'espresso':
          code = _exportEspresso();
          break;
        default:
          code = jsonEncode(_recordedSteps);
      }
      return {"format": format, "code": code, "step_count": _recordedSteps.length};
    }

    // Video recording tools
    if (name == 'video_start') {
      if (_videoProcess != null) {
        return {"success": false, "error": "Video recording already in progress"};
      }
      final platform = await _detectSimulatorPlatform();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = args['path'] as String? ??
          '${Directory.systemTemp.path}/flutter_skill_video_$timestamp.${platform == 'ios' ? 'mov' : 'mp4'}';
      try {
        Process process;
        if (platform == 'ios') {
          process = await Process.start('xcrun', ['simctl', 'io', 'booted', 'recordVideo', path]);
          _videoProcess = process;
          _videoPath = path;
        } else {
          // Android: record on device, pull later
          final devicePath = '/sdcard/flutter_skill_video_$timestamp.mp4';
          final adb = _findAdb();
          process = await Process.start(adb, ['-s', 'emulator-5554', 'shell', 'screenrecord', devicePath]);
          _videoProcess = process;
          _videoPath = path; // local path for after pull
          _videoDevicePath = devicePath;
        }
        _videoPlatform = platform;
        return {"recording": true, "platform": platform, "path": path};
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    if (name == 'video_stop') {
      if (_videoProcess == null) {
        return {"success": false, "error": "No video recording in progress"};
      }
      try {
        _videoProcess!.kill(ProcessSignal.sigint);
        await _videoProcess!.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
          _videoProcess!.kill();
          return -1;
        });
      } catch (_) {}
      final path = _videoPath;
      final platform = _videoPlatform;
      final devicePath = _videoDevicePath;
      _videoProcess = null;
      _videoPath = null;
      _videoPlatform = null;
      _videoDevicePath = null;
      // For Android, pull the file from device
      if (platform == 'android' && devicePath != null && path != null) {
        try {
          await Process.run(_findAdb(), ['-s', 'emulator-5554', 'pull', devicePath, path]);
        } catch (_) {}
      }
      return {"path": path, "platform": platform, "success": true};
    }

    // Parallel multi-device tools
    if (name == 'parallel_snapshot') {
      final sessionIds = (args['session_ids'] as List<dynamic>?)?.cast<String>() ?? _sessions.keys.toList();
      final futures = sessionIds.map((sid) async {
        try {
          final c = _clients[sid];
          if (c == null) return {"session_id": sid, "error": "Not connected"};
          if (c is FlutterSkillClient) {
            final structured = await c.getInteractiveElementsStructured();
            return {"session_id": sid, "snapshot": structured, "platform": _sessions[sid]?.deviceId};
          }
          return {"session_id": sid, "error": "Not a Flutter client"};
        } catch (e) {
          return {"session_id": sid, "error": e.toString()};
        }
      });
      final results = await Future.wait(futures);
      return {"devices": results, "device_count": results.length};
    }

    if (name == 'parallel_tap') {
      final sessionIds = (args['session_ids'] as List<dynamic>?)?.cast<String>() ?? _sessions.keys.toList();
      final ref = args['ref'] as String?;
      final key = args['key'] as String?;
      final text = args['text'] as String?;
      final futures = sessionIds.map((sid) async {
        try {
          final c = _clients[sid];
          if (c == null) return {"session_id": sid, "success": false, "error": "Not connected"};
          final result = await c.tap(key: key, text: text, ref: ref);
          return {"session_id": sid, "success": true, "platform": _sessions[sid]?.deviceId, "result": result};
        } catch (e) {
          return {"session_id": sid, "success": false, "error": e.toString()};
        }
      });
      final results = await Future.wait(futures);
      return {"results": results};
    }

    if (name == 'multi_platform_test') {
      final actions = (args['actions'] as List<dynamic>?) ?? [];
      final sessionIds = (args['session_ids'] as List<dynamic>?)?.cast<String>() ?? _sessions.keys.toList();
      final stopOnFailure = args['stop_on_failure'] as bool? ?? false;
      final savedSessionId = _activeSessionId;

      final futures = sessionIds.map((sid) async {
        final platform = _sessions[sid]?.deviceId ?? 'unknown';
        final steps = <Map<String, dynamic>>[];
        int passed = 0;
        int failed = 0;
        bool stopped = false;

        for (final action in actions) {
          if (stopped) break;
          final toolName = (action as Map<String, dynamic>)['tool'] as String? ?? '';
          final toolArgs = Map<String, dynamic>.from(
            (action['args'] as Map<String, dynamic>?) ?? {},
          );
          toolArgs['session_id'] = sid;

          final sw = Stopwatch()..start();
          try {
            // Temporarily switch active session for tools that rely on it
            _activeSessionId = sid;
            final result = await _executeToolInner(toolName, toolArgs);
            sw.stop();
            final success = result is Map ? (result['error'] == null) : true;
            steps.add({'tool': toolName, 'success': success, 'time_ms': sw.elapsedMilliseconds});
            if (success) {
              passed++;
            } else {
              failed++;
              if (stopOnFailure) stopped = true;
            }
          } catch (e) {
            sw.stop();
            steps.add({'tool': toolName, 'success': false, 'time_ms': sw.elapsedMilliseconds, 'error': e.toString()});
            failed++;
            if (stopOnFailure) stopped = true;
          }
        }

        return MapEntry(sid, {
          'platform': platform,
          'steps': steps,
          'passed': passed,
          'failed': failed,
        });
      });

      final entries = await Future.wait(futures);
      _activeSessionId = savedSessionId;

      final results = Map.fromEntries(entries);
      final allPassed = results.values.where((r) => (r['failed'] as int) == 0).length;
      final someFailed = results.values.where((r) => (r['failed'] as int) > 0).length;

      return {
        'platforms_tested': sessionIds.length,
        'results': results,
        'summary': {
          'total_platforms': sessionIds.length,
          'all_passed': allPassed,
          'some_failed': someFailed,
        },
      };
    }

    if (name == 'compare_platforms') {
      final sessionIds = (args['session_ids'] as List<dynamic>?)?.cast<String>() ?? _sessions.keys.toList();

      // Take snapshots from all platforms in parallel
      final futures = sessionIds.map((sid) async {
        try {
          final c = _clients[sid];
          if (c == null) return MapEntry(sid, <String, dynamic>{'error': 'Not connected'});
          if (c is FlutterSkillClient) {
            final structured = await c.getInteractiveElementsStructured();
            final elements = (structured is Map && structured['elements'] is List)
                ? (structured['elements'] as List)
                : <dynamic>[];
            final elementKeys = <String>{};
            for (final el in elements) {
              if (el is Map) {
                final type = el['type'] as String? ?? '';
                final text = el['text'] as String? ?? el['label'] as String? ?? '';
                elementKeys.add('$type:$text');
              }
            }
            return MapEntry(sid, <String, dynamic>{
              'platform': _sessions[sid]?.deviceId ?? 'unknown',
              'element_count': elements.length,
              'elements': elementKeys.toList(),
            });
          }
          return MapEntry(sid, <String, dynamic>{'error': 'Not a Flutter client'});
        } catch (e) {
          return MapEntry(sid, <String, dynamic>{'error': e.toString()});
        }
      });

      final entries = await Future.wait(futures);
      final platformData = Map.fromEntries(entries);

      // Find all unique element keys across platforms
      final allElements = <String>{};
      final platformElements = <String, Set<String>>{};
      for (final entry in platformData.entries) {
        if (entry.value.containsKey('elements')) {
          final elems = (entry.value['elements'] as List).cast<String>().toSet();
          platformElements[entry.key] = elems;
          allElements.addAll(elems);
        }
      }

      // Build presence matrix and find inconsistencies
      final inconsistencies = <Map<String, dynamic>>[];
      final presenceMatrix = <String, Map<String, bool>>{};
      for (final element in allElements) {
        final presence = <String, bool>{};
        for (final sid in platformElements.keys) {
          presence[sid] = platformElements[sid]!.contains(element);
        }
        presenceMatrix[element] = presence;
        // If not present on all platforms, it's an inconsistency
        if (presence.values.any((v) => !v)) {
          inconsistencies.add({
            'element': element,
            'present_on': presence.entries.where((e) => e.value).map((e) => e.key).toList(),
            'missing_on': presence.entries.where((e) => !e.value).map((e) => e.key).toList(),
          });
        }
      }

      return {
        'platforms': platformData,
        'total_unique_elements': allElements.length,
        'inconsistencies': inconsistencies,
        'consistent': inconsistencies.isEmpty,
      };
    }

    // Auth inject session
    if (name == 'auth_inject_session') {
      final token = args['token'] as String;
      final key = args['key'] as String? ?? 'auth_token';
      final storageType = args['storage_type'] as String? ?? 'shared_preferences';
      // Detect platform from active connection
      final platform = await _detectSimulatorPlatform();
      
      // For web/electron/tauri: inject via JavaScript
      if (storageType == 'cookie' || storageType == 'local_storage' || platform == 'web') {
        final js = storageType == 'cookie'
            ? "document.cookie='$key=$token; path=/'"
            : "window.localStorage.setItem('$key','$token')";
        // If connected to a bridge with eval support, execute directly
        final client = _getClient(args);
        if (client is BridgeDriver) {
          try {
            final evalResult = await client.callMethod('eval', {'expression': js});
            return {"success": true, "storage_type": storageType, "key": key, "platform": platform, "injected": true, "eval_result": evalResult};
          } catch (_) {
            // Fall back to returning snippet
          }
        }
        return {"success": true, "storage_type": storageType, "key": key, "js_snippet": js, "platform": platform, "note": "Execute this JS in your web app's console"};
      }
      // For shared_preferences on mobile: provide instruction
      try {
        return {"success": true, "storage_type": storageType, "key": key, "token": token, "platform": platform, "note": "Token prepared for injection. Use hot_restart to pick up changes."};
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    // Platform-agnostic tools that work on any connection type
    if (name == 'list_plugins') {
      return _pluginTools.isEmpty
          ? {"plugins": [], "message": "No plugins loaded"}
          : {"plugins": _pluginTools.map((p) => {"name": p['name'], "description": p['description']}).toList()};
    }

    if (name == 'generate_report') {
      return _generateReport(args);
    }

    // Require connection for all other tools
    final client = _getClient(args);
    _requireConnection(client);

    if (name == 'assert_batch') {
      return _executeBatchAssertions(args, client!);
    }

    if (name == 'visual_verify') {
      return _executeVisualVerify(args, client!);
    }

    if (name == 'visual_diff') {
      return _executeVisualDiff(args, client!);
    }

    // Route to CDP driver if active connection is CDP
    if (client is CdpDriver) {
      return await _executeCdpTool(name, args, client);
    }

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
      case 'inspect_interactive':
        if (client is BridgeDriver) {
          return await client.getInteractiveElementsStructured();
        }
        final fc = _asFlutterClient(client!, 'inspect_interactive');
        return await fc.getInteractiveElementsStructured();
      case 'snapshot':
        final snapshotMode = args['mode'] as String? ?? 'text';
        if (snapshotMode == 'vision') {
          final imageBase64 = await client!.takeScreenshot(quality: 0.5, maxWidth: 800);
          if (imageBase64 == null) return {"success": false, "error": "Failed to capture screenshot"};
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file = File('${tempDir.path}/flutter_skill_vision_$timestamp.png');
          await file.writeAsBytes(base64.decode(imageBase64));
          return {"mode": "vision", "path": file.path, "success": true};
        }
        final structured = await client!.getInteractiveElementsStructured();
        final snapshotElements = structured['elements'] as List<dynamic>? ?? [];
        
        // Also get all elements (including non-interactive) for richer snapshot
        List<dynamic> allElements = [];
        try {
          allElements = await client.getInteractiveElements();
        } catch (_) {
          // Fall back to interactive-only if full inspect fails
        }
        
        // Build text-based accessibility tree
        final buffer = StringBuffer();
        
        // Build interactive ref set for quick lookup
        final refSet = <String>{};
        for (final el in snapshotElements) {
          if (el is Map && el['ref'] != null) {
            refSet.add(el['ref'].toString());
          }
        }
        
        // Merge: interactive elements have refs, non-interactive are context
        final allMerged = <Map<String, dynamic>>[];
        
        // Add interactive elements with full data
        for (final el in snapshotElements) {
          if (el is Map<String, dynamic>) {
            allMerged.add({...el, '_interactive': true});
          }
        }
        
        // Add non-interactive elements from inspect (text, images, etc.)
        for (final el in allElements) {
          if (el is Map<String, dynamic>) {
            final isInteractive = el['clickable'] == true || 
                                  el['type']?.toString().contains('Button') == true ||
                                  el['type']?.toString().contains('TextField') == true ||
                                  el['type']?.toString().contains('Input') == true;
            if (!isInteractive) {
              allMerged.add({...el, '_interactive': false});
            }
          }
        }
        
        // Sort by position (top to bottom, left to right)
        allMerged.sort((a, b) {
          final aB = a['bounds'] as Map<String, dynamic>?;
          final bB = b['bounds'] as Map<String, dynamic>?;
          final ay = (aB?['y'] ?? 0) as num;
          final by = (bB?['y'] ?? 0) as num;
          if (ay != by) return ay.compareTo(by);
          final ax = (aB?['x'] ?? 0) as num;
          final bx = (bB?['x'] ?? 0) as num;
          return ax.compareTo(bx);
        });
        
        // Format as tree
        for (var i = 0; i < allMerged.length; i++) {
          final el = allMerged[i];
          final isLast = i == allMerged.length - 1;
          final prefix = isLast ? '└── ' : '├── ';
          final bounds = el['bounds'] as Map<String, dynamic>?;
          final bStr = bounds != null ? '(${bounds['x']},${bounds['y']} ${bounds['w']}x${bounds['h']})' : '';
          
          if (el['_interactive'] == true) {
            // Interactive element with ref
            final ref = el['ref'] ?? '';
            final text = el['text']?.toString() ?? '';
            final label = el['label']?.toString() ?? '';
            final value = el['value']?.toString();
            final enabled = el['enabled'] != false;
            final actions = (el['actions'] as List?)?.join(',') ?? '';
            
            String displayText = text.isNotEmpty ? text : label;
            if (displayText.length > 40) displayText = '${displayText.substring(0, 37)}...';
            
            final valuePart = value != null && value.isNotEmpty ? ' value="$value"' : '';
            final enabledPart = enabled ? '' : ' DISABLED';
            
            buffer.writeln('$prefix[$ref] "$displayText" $bStr$valuePart$enabledPart {$actions}');
          } else {
            // Non-interactive element (context)
            final type = el['type']?.toString() ?? 'unknown';
            final text = el['text']?.toString() ?? '';
            final shortType = type.replaceAll('RenderObjectToWidgetAdapter<RenderBox>', 'Root')
                                  .split('.').last;
            
            if (text.isNotEmpty) {
              String displayText = text;
              if (displayText.length > 50) displayText = '${displayText.substring(0, 47)}...';
              buffer.writeln('$prefix[$shortType] "$displayText" $bStr');
            }
            // Skip non-text non-interactive elements to keep snapshot compact
          }
        }
        
        final snapshotText = buffer.toString();
        final summary = structured['summary'] ?? '';
        
        final result = <String, dynamic>{
          'snapshot': snapshotText,
          'summary': summary,
          'elementCount': allMerged.length,
          'interactiveCount': snapshotElements.length,
          'tokenEstimate': snapshotText.length ~/ 4,
          'hint': 'Use ref IDs to interact: tap(ref: "button:Login"), enter_text(ref: "input:Email", text: "...")',
        };
        if (snapshotMode == 'smart') {
          final hasVisual = allMerged.any((el) {
            final type = (el['type'] ?? '').toString().toLowerCase();
            return type.contains('image') || type.contains('video') || type.contains('picture') || type.contains('icon');
          });
          if (hasVisual) {
            result['has_visual_content'] = true;
            result['hint'] = 'Use screenshot() if you need to verify images/visual layout. ' + (result['hint'] as String);
          }
        }
        return result;
      case 'get_widget_tree':
        final fc = _asFlutterClient(client!, 'get_widget_tree');
        final maxDepth = args['max_depth'] ?? 10;
        return await fc.getWidgetTree(maxDepth: maxDepth);
      case 'get_widget_properties':
        final fc = _asFlutterClient(client!, 'get_widget_properties');
        return await fc.getWidgetProperties(args['key']);
      case 'get_text_content':
        if (client is BridgeDriver) {
          final text = await client.getText();
          return {"success": true, "text": text};
        }
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

        // Method 3: Tap by coordinates
        if (x != null && y != null) {
          if (client is BridgeDriver) {
            await client.callMethod('tap_at', {'x': x.toDouble(), 'y': y.toDouble()});
            return {"success": true, "method": "coordinates", "message": "Tapped at ($x, $y)", "position": {"x": x, "y": y}};
          }
          final fc = _asFlutterClient(client!, 'tap (coordinates)');
          await fc.tapAt(x.toDouble(), y.toDouble());
          return {
            "success": true,
            "method": "coordinates",
            "message": "Tapped at ($x, $y)",
            "position": {"x": x, "y": y},
          };
        }

        // Method 1 & 2: Tap by key, text, or semantic ref
        final result = await client!.tap(
          key: args['key'], 
          text: args['text'],
          ref: args['ref'],
        );
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
        final result = await client!.enterText(
          args['key'], 
          args['text'], 
          ref: args['ref'],
        );
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
        if (client is BridgeDriver) {
          await client.scroll(direction: args['direction'] ?? 'down', distance: args['distance'] ?? 300);
          return {"success": true, "message": "Scrolled"};
        }
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
        if (client is BridgeDriver) {
          final success = await client.longPress(key: args['key'], text: args['text']);
          return success ? "Long pressed" : "Long press failed";
        }
        final fc = _asFlutterClient(client!, 'long_press');
        final duration = args['duration'] ?? 500;
        final success = await fc.longPress(
            key: args['key'], text: args['text'], duration: duration);
        return success ? "Long pressed" : "Long press failed";
      case 'double_tap':
        if (client is BridgeDriver) {
          final success = await client.doubleTap(key: args['key'], text: args['text']);
          return success ? "Double tapped" : "Double tap failed";
        }
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
        if (client is BridgeDriver) {
          final result = await client.callMethod('drag', {'from_key': args['from_key'], 'to_key': args['to_key']});
          return result['success'] == true ? "Dragged" : "Drag failed";
        }
        final fc = _asFlutterClient(client!, 'drag');
        final success =
            await fc.drag(fromKey: args['from_key'], toKey: args['to_key']);
        return success ? "Dragged" : "Drag failed";

      // State & Validation
      case 'get_text_value':
        if (client is BridgeDriver) {
          final text = await client.getText(key: args['key']);
          return {"success": true, "text": text};
        }
        final fc = _asFlutterClient(client!, 'get_text_value');
        return await fc.getTextValue(args['key']);
      case 'get_checkbox_state':
        if (client is BridgeDriver) {
          return await client.callMethod('get_checkbox_state', {'key': args['key']});
        }
        final fc = _asFlutterClient(client!, 'get_checkbox_state');
        return await fc.getCheckboxState(args['key']);
      case 'get_slider_value':
        if (client is BridgeDriver) {
          return await client.callMethod('get_slider_value', {'key': args['key']});
        }
        final fc = _asFlutterClient(client!, 'get_slider_value');
        return await fc.getSliderValue(args['key']);
      case 'wait_for_element':
        if (client is BridgeDriver) {
          final timeout = args['timeout'] ?? 5000;
          final found = await client.waitForElement(key: args['key'], text: args['text'], timeout: timeout);
          return {"found": found};
        }
        final fc = _asFlutterClient(client!, 'wait_for_element');
        final timeout = args['timeout'] ?? 5000;
        final found = await fc.waitForElement(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"found": found};
      case 'wait_for_gone':
        if (client is BridgeDriver) {
          final result = await client.callMethod('wait_for_gone', {'key': args['key'], 'text': args['text'], 'timeout': args['timeout'] ?? 5000});
          return {"gone": result['gone'] ?? true};
        }
        final fc = _asFlutterClient(client!, 'wait_for_gone');
        final timeout = args['timeout'] ?? 5000;
        final gone = await fc.waitForGone(
            key: args['key'], text: args['text'], timeout: timeout);
        return {"gone": gone};

      // Screenshot
      case 'screenshot':
        // Default to lower quality and max width to prevent token overflow
        final quality = (args['quality'] as num?)?.toDouble() ?? 0.8;
        final maxWidth = args['max_width'] as int? ?? 800;
        final saveToFile =
            args['save_to_file'] ?? false; // Return base64 by default for speed

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
        if (client is BridgeDriver) {
          final result = await client.callMethod('screenshot_region', {
            'x': (args['x'] as num).toDouble(), 'y': (args['y'] as num).toDouble(),
            'width': (args['width'] as num).toDouble(), 'height': (args['height'] as num).toDouble(),
          });
          return result;
        }
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

      // AI Visual Verification
      case 'visual_verify':
        final verifyQuality = (args['quality'] as num?)?.toDouble() ?? 0.5;
        final verifyDesc = args['description'] as String? ?? '';
        final checkElements = (args['check_elements'] as List?)?.cast<String>() ?? [];

        // Take screenshot
        final verifyImageBase64 = await client!.takeScreenshot(quality: verifyQuality, maxWidth: 800);
        String? verifyScreenshotPath;
        if (verifyImageBase64 != null) {
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file = File('${tempDir.path}/flutter_skill_verify_$timestamp.png');
          await file.writeAsBytes(base64.decode(verifyImageBase64));
          verifyScreenshotPath = file.path;
        }

        // Take snapshot (text tree)
        String verifySnapshotText = '';
        List<String> foundElements = [];
        List<String> missingElements = [];
        int verifyElementCount = 0;
        try {
          final structured = await client!.getInteractiveElementsStructured();
          final snapshotElements = structured['elements'] as List<dynamic>? ?? [];
          verifyElementCount = snapshotElements.length;

          final buf = StringBuffer();
          for (var i = 0; i < snapshotElements.length; i++) {
            final el = snapshotElements[i] as Map<String, dynamic>;
            final ref = el['ref'] ?? '';
            final text = el['text']?.toString() ?? '';
            final label = el['label']?.toString() ?? '';
            final display = text.isNotEmpty ? text : label;
            buf.writeln('[$ref] "$display"');
          }
          verifySnapshotText = buf.toString();

          // Check elements
          if (checkElements.isNotEmpty) {
            final snapshotLower = verifySnapshotText.toLowerCase();
            for (final check in checkElements) {
              if (snapshotLower.contains(check.toLowerCase())) {
                foundElements.add(check);
              } else {
                missingElements.add(check);
              }
            }
          }
        } catch (e) {
          verifySnapshotText = 'Error getting snapshot: $e';
        }

        return {
          'success': true,
          'screenshot': verifyScreenshotPath,
          'snapshot': verifySnapshotText,
          'elements_found': foundElements,
          'elements_missing': missingElements,
          'element_count': verifyElementCount,
          'description_to_verify': verifyDesc,
          'hint': 'Compare the screenshot and snapshot against the description. Report any discrepancies.',
        };

      case 'visual_diff':
        final diffQuality = (args['quality'] as num?)?.toDouble() ?? 0.5;
        final baselinePath = args['baseline_path'] as String;
        final diffDesc = args['description'] as String? ?? '';

        final baselineFile = File(baselinePath);
        if (!await baselineFile.exists()) {
          return {'success': false, 'error': 'Baseline file not found: $baselinePath'};
        }

        final diffImageBase64 = await client!.takeScreenshot(quality: diffQuality, maxWidth: 800);
        String? currentScreenshotPath;
        if (diffImageBase64 != null) {
          final tempDir = Directory.systemTemp;
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file = File('${tempDir.path}/flutter_skill_diff_$timestamp.png');
          await file.writeAsBytes(base64.decode(diffImageBase64));
          currentScreenshotPath = file.path;
        }

        String diffSnapshotText = '';
        try {
          final structured = await client!.getInteractiveElementsStructured();
          final els = structured['elements'] as List<dynamic>? ?? [];
          final buf = StringBuffer();
          for (final el in els) {
            if (el is Map<String, dynamic>) {
              final ref = el['ref'] ?? '';
              final text = el['text']?.toString() ?? '';
              final label = el['label']?.toString() ?? '';
              buf.writeln('[$ref] "${text.isNotEmpty ? text : label}"');
            }
          }
          diffSnapshotText = buf.toString();
        } catch (e) {
          diffSnapshotText = 'Error: $e';
        }

        return {
          'success': true,
          'baseline_path': baselinePath,
          'current_screenshot': currentScreenshotPath,
          'current_snapshot': diffSnapshotText,
          'description': diffDesc,
          'hint': 'Compare the baseline screenshot with the current screenshot. Look for visual differences. The text snapshot shows the current UI structure.',
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

        if (client is BridgeDriver) {
          final result = await client.callMethod('screenshot_element', {'key': targetKey});
          return result;
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
        if (client is BridgeDriver) {
          final route = await client.getRoute();
          return {"route": route};
        }
        final fc = _asFlutterClient(client!, 'get_current_route');
        return await fc.getCurrentRoute();
      case 'go_back':
        if (client is BridgeDriver) {
          final success = await client.goBack();
          return success ? "Navigated back" : "Cannot go back";
        }
        final fc = _asFlutterClient(client!, 'go_back');
        final success = await fc.goBack();
        return success ? "Navigated back" : "Cannot go back";
      case 'get_navigation_stack':
        if (client is BridgeDriver) {
          return await client.callMethod('get_navigation_stack');
        }
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
        if (client is BridgeDriver) {
          return await client.callMethod('get_errors', {'limit': args['limit'] ?? 50, 'offset': args['offset'] ?? 0});
        }
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
        if (client is BridgeDriver) {
          return await client.callMethod('get_performance');
        }
        final fc = _asFlutterClient(client!, 'get_performance');
        return await fc.getPerformance();

      // === HTTP / Network Monitoring ===
      case 'enable_network_monitoring':
        if (client is BridgeDriver) {
          return await client.callMethod('enable_network_monitoring', {'enable': args['enable'] ?? true});
        }
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
        if (client is BridgeDriver) {
          return await client.callMethod('get_network_requests', {'limit': args['limit'] ?? 20});
        }
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
        if (client is BridgeDriver) {
          return await client.callMethod('clear_network_requests');
        }
        final fc = _asFlutterClient(client!, 'clear_network_requests');
        await fc.clearHttpRequests();
        return {"success": true, "message": "Network request history cleared"};

      // === NEW: Batch Operations ===
      case 'execute_batch':
        if (client is BridgeDriver) {
          final actions = args['actions'] as List? ?? [];
          final results = <Map<String, dynamic>>[];
          for (final action in actions) {
            if (action is Map<String, dynamic>) {
              final toolName = action['tool'] as String?;
              final toolArgs = Map<String, dynamic>.from(action['args'] as Map? ?? {});
              if (toolName != null) {
                try {
                  final result = await client.callMethod(toolName, toolArgs);
                  results.add({'tool': toolName, 'success': true, 'result': result});
                } catch (e) {
                  results.add({'tool': toolName, 'success': false, 'error': e.toString()});
                }
              }
            }
          }
          return {"success": true, "results": results, "count": results.length};
        }
        final fc = _asFlutterClient(client!, 'execute_batch');
        return await _executeBatch(args, fc);

      // === NEW: Coordinate-based Actions ===
      case 'tap_at':
        if (client is BridgeDriver) {
          await client.callMethod('tap_at', {'x': (args['x'] as num).toDouble(), 'y': (args['y'] as num).toDouble()});
          return {"success": true, "action": "tap_at", "x": args['x'], "y": args['y']};
        }
        final fc = _asFlutterClient(client!, 'tap_at');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        await fc.tapAt(x, y);
        return {"success": true, "action": "tap_at", "x": x, "y": y};

      case 'long_press_at':
        if (client is BridgeDriver) {
          await client.callMethod('long_press_at', {'x': (args['x'] as num).toDouble(), 'y': (args['y'] as num).toDouble(), 'duration': args['duration'] ?? 500});
          return {"success": true, "action": "long_press_at", "x": args['x'], "y": args['y']};
        }
        final fc = _asFlutterClient(client!, 'long_press_at');
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final duration = args['duration'] ?? 500;
        await fc.longPressAt(x, y, duration: duration);
        return {"success": true, "action": "long_press_at", "x": x, "y": y};

      case 'swipe_coordinates':
        if (client is BridgeDriver) {
          await client.callMethod('swipe_coordinates', {
            'start_x': ((args['start_x'] ?? args['startX']) as num).toDouble(),
            'start_y': ((args['start_y'] ?? args['startY']) as num).toDouble(),
            'end_x': ((args['end_x'] ?? args['endX']) as num).toDouble(),
            'end_y': ((args['end_y'] ?? args['endY']) as num).toDouble(),
            'duration': args['duration'] ?? args['durationMs'] ?? 300,
          });
          return {"success": true, "action": "swipe_coordinates"};
        }
        final fc = _asFlutterClient(client!, 'swipe_coordinates');
        final startX = ((args['start_x'] ?? args['startX']) as num).toDouble();
        final startY = ((args['start_y'] ?? args['startY']) as num).toDouble();
        final endX = ((args['end_x'] ?? args['endX']) as num).toDouble();
        final endY = ((args['end_y'] ?? args['endY']) as num).toDouble();
        final duration = args['duration'] ?? 300;
        await fc.swipeCoordinates(startX, startY, endX, endY,
            duration: duration);
        return {"success": true, "action": "swipe_coordinates"};

      case 'edge_swipe':
        if (client is BridgeDriver) {
          return await client.callMethod('edge_swipe', {'edge': args['edge'], 'direction': args['direction'], 'distance': (args['distance'] as num?)?.toDouble() ?? 200});
        }
        final fc = _asFlutterClient(client!, 'edge_swipe');
        final edge = args['edge'] as String;
        final direction = args['direction'] as String;
        final distance = (args['distance'] as num?)?.toDouble() ?? 200;
        final result = await fc.edgeSwipe(
            edge: edge, direction: direction, distance: distance);
        return result;

      case 'gesture':
        if (client is BridgeDriver) {
          return await client.callMethod('gesture', args);
        }
        final fc = _asFlutterClient(client!, 'gesture');
        return await _performGesture(args, fc);

      case 'wait_for_idle':
        if (client is BridgeDriver) {
          return {"success": true, "message": "Bridge platform ready"};
        }
        final fc = _asFlutterClient(client!, 'wait_for_idle');
        return await _waitForIdle(args, fc);

      // === NEW: Smart Scroll ===
      case 'scroll_until_visible':
        if (client is BridgeDriver) {
          return await client.callMethod('scroll_until_visible', {'key': args['key'], 'text': args['text'], 'direction': args['direction'] ?? 'down', 'max_scrolls': args['max_scrolls'] ?? 10});
        }
        final fc = _asFlutterClient(client!, 'scroll_until_visible');
        return await _scrollUntilVisible(args, fc);

      // === Batch Assertions ===
      case 'assert_batch':
        final assertions = (args['assertions'] as List<dynamic>?) ?? [];
        final results = <Map<String, dynamic>>[];
        int passed = 0;
        int failed = 0;
        for (final assertion in assertions) {
          final a = assertion as Map<String, dynamic>;
          final aType = a['type'] as String;
          try {
            final toolName = aType == 'visible' ? 'assert_visible'
                : aType == 'not_visible' ? 'assert_not_visible'
                : aType == 'text' ? 'assert_text'
                : aType == 'element_count' ? 'assert_element_count'
                : aType;
            final toolArgs = <String, dynamic>{
              if (a['key'] != null) 'key': a['key'],
              if (a['text'] != null) 'text': a['text'],
              if (a['expected'] != null) 'expected': a['expected'],
              if (a['count'] != null) 'expected_count': a['count'],
            };
            final result = await _executeToolInner(toolName, toolArgs);
            final success = result is Map && result['success'] == true;
            if (success) passed++; else failed++;
            results.add({'type': aType, 'success': success, 'result': result});
          } catch (e) {
            failed++;
            results.add({'type': aType, 'success': false, 'error': e.toString()});
          }
        }
        return {
          'success': failed == 0,
          'total': assertions.length,
          'passed': passed,
          'failed': failed,
          'results': results,
        };

      // === NEW: Assertions ===
      case 'assert_visible':
        if (client is BridgeDriver) {
          final found = await client.findElement(key: args['key'], text: args['text']);
          final isVisible = found.isNotEmpty && found['found'] == true;
          return {"success": isVisible, "visible": isVisible, "message": isVisible ? "Element is visible" : "Element not found"};
        }
        final fc = _asFlutterClient(client!, 'assert_visible');
        return await _assertVisible(args, fc, shouldBeVisible: true);

      case 'assert_not_visible':
        if (client is BridgeDriver) {
          final found = await client.findElement(key: args['key'], text: args['text']);
          final isGone = found.isEmpty || found['found'] != true;
          return {"success": isGone, "visible": !isGone, "message": isGone ? "Element is not visible" : "Element is still visible"};
        }
        final fc = _asFlutterClient(client!, 'assert_not_visible');
        return await _assertVisible(args, fc, shouldBeVisible: false);

      case 'assert_text':
        if (client is BridgeDriver) {
          final actual = await client.getText(key: args['key']);
          final expected = args['expected'] as String?;
          final matches = actual == expected;
          return {"success": matches, "actual": actual, "expected": expected, "message": matches ? "Text matches" : "Text mismatch"};
        }
        final fc = _asFlutterClient(client!, 'assert_text');
        return await _assertText(args, fc);

      case 'assert_element_count':
        if (client is BridgeDriver) {
          final elements = await client.getInteractiveElements();
          final count = elements.length;
          final expected = args['expected'] as int?;
          final matches = expected == null || count == expected;
          return {"success": matches, "count": count, "expected": expected, "message": matches ? "Count matches" : "Expected $expected but found $count"};
        }
        final fc = _asFlutterClient(client!, 'assert_element_count');
        return await _assertElementCount(args, fc);

      // === NEW: Page State ===
      case 'get_page_state':
        if (client is BridgeDriver) {
          final route = await client.getRoute();
          final structured = await client.getInteractiveElementsStructured();
          return {"route": route, "elements": structured};
        }
        final fc = _asFlutterClient(client!, 'get_page_state');
        return await _getPageState(fc);

      case 'get_interactable_elements':
        final includePositions = args['include_positions'] ?? true;
        return await client!
            .getInteractiveElements(includePositions: includePositions);

      // === NEW: Performance & Memory ===
      case 'get_frame_stats':
        if (client is BridgeDriver) {
          return await client.callMethod('get_frame_stats');
        }
        final fc = _asFlutterClient(client!, 'get_frame_stats');
        return await fc.getFrameStats();

      case 'get_memory_stats':
        if (client is BridgeDriver) {
          return await client.callMethod('get_memory_stats');
        }
        final fc = _asFlutterClient(client!, 'get_memory_stats');
        return await fc.getMemoryStats();

      // === Smart Diagnosis ===
      case 'diagnose':
        if (client is BridgeDriver) {
          return await client.callMethod('diagnose', args);
        }
        final fc = _asFlutterClient(client!, 'diagnose');
        return await _performDiagnosis(args, fc);

      case 'list_plugins':
        return {
          'plugins': _pluginTools.map((p) => {
            'name': p['name'],
            'description': p['description'],
            'steps': (p['steps'] as List).length,
            'source': p['source'],
          }).toList(),
          'count': _pluginTools.length,
        };

      case 'generate_report':
        return await _generateReport(args);

      default:
        // Check plugin tools
        final plugin = _pluginTools.cast<Map<String, dynamic>?>().firstWhere(
          (p) => p!['name'] == name,
          orElse: () => null,
        );
        if (plugin != null) {
          return await _executePlugin(plugin, args);
        }
        throw Exception("Unknown tool: $name");
    }
  }

  /// Execute a tool via CDP driver
  Future<dynamic> _executeCdpTool(String name, Map<String, dynamic> args, CdpDriver cdp) async {
    switch (name) {
      case 'inspect':
        final elements = await cdp.getInteractiveElements();
        final currentPageOnly = args['current_page_only'] ?? true;
        if (currentPageOnly) {
          return elements.where((e) {
            if (e is! Map) return true;
            final bounds = e['bounds'];
            if (bounds == null) return true;
            return (bounds['x'] as int? ?? 0) >= -10 && (bounds['y'] as int? ?? 0) >= -10;
          }).toList();
        }
        return elements;

      case 'inspect_interactive':
        return await cdp.getInteractiveElementsStructured();

      case 'snapshot':
        final structured = await cdp.getInteractiveElementsStructured();
        final elements = structured['elements'] as List<dynamic>? ?? [];
        final buffer = StringBuffer();
        for (var i = 0; i < elements.length; i++) {
          final el = elements[i] as Map<String, dynamic>;
          final isLast = i == elements.length - 1;
          final prefix = isLast ? '└── ' : '├── ';
          final ref = el['ref'] ?? '';
          final text = (el['text'] ?? el['label'] ?? '').toString();
          final displayText = text.length > 40 ? '${text.substring(0, 37)}...' : text;
          final bounds = el['bounds'] as Map<String, dynamic>?;
          final bStr = bounds != null ? '(${bounds['x']},${bounds['y']} ${bounds['w']}x${bounds['h']})' : '';
          final valuePart = (el['value'] != null && el['value'].toString().isNotEmpty) ? ' value="${el['value']}"' : '';
          final enabledPart = el['enabled'] == false ? ' DISABLED' : '';
          final actions = (el['actions'] as List?)?.join(',') ?? '';
          buffer.writeln('$prefix[$ref] "$displayText" $bStr$valuePart$enabledPart {$actions}');
        }
        return {
          'snapshot': buffer.toString(),
          'summary': structured['summary'] ?? '',
          'elementCount': elements.length,
          'interactiveCount': elements.length,
          'tokenEstimate': buffer.length ~/ 4,
          'hint': 'Use ref IDs to interact: tap(ref: "button:Login"), enter_text(ref: "input:Email", text: "...")',
        };

      case 'tap':
        final x = args['x'] as num?;
        final y = args['y'] as num?;
        if (x != null && y != null) {
          await cdp.tapAt(x.toDouble(), y.toDouble());
          return {"success": true, "method": "coordinates", "position": {"x": x, "y": y}};
        }
        return await cdp.tap(key: args['key'], text: args['text'], ref: args['ref']);

      case 'enter_text':
        return await cdp.enterText(args['key'], args['text'], ref: args['ref']);

      case 'screenshot':
        final quality = (args['quality'] as num?)?.toDouble() ?? 0.8;
        final saveToFile = args['save_to_file'] ?? false;
        final imageBase64 = await cdp.takeScreenshot(quality: quality);
        if (imageBase64 == null) {
          return {"success": false, "error": "Failed to capture screenshot"};
        }
        if (saveToFile) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file = File('${Directory.systemTemp.path}/flutter_skill_screenshot_$timestamp.jpg');
          final bytes = base64.decode(imageBase64);
          await file.writeAsBytes(bytes);
          return {"success": true, "file_path": file.path, "size_bytes": bytes.length, "format": "jpeg"};
        }
        return {"image": imageBase64, "quality": quality};

      case 'screenshot_region':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        final width = (args['width'] as num).toDouble();
        final height = (args['height'] as num).toDouble();
        final saveToFile = args['save_to_file'] ?? false;
        final image = await cdp.takeRegionScreenshot(x, y, width, height);
        if (image == null) return {"success": false, "error": "Failed to capture region screenshot"};
        if (saveToFile) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final file = File('${Directory.systemTemp.path}/flutter_skill_region_$timestamp.jpg');
          final bytes = base64.decode(image);
          await file.writeAsBytes(bytes);
          return {"success": true, "file_path": file.path, "size_bytes": bytes.length, "region": {"x": x, "y": y, "width": width, "height": height}};
        }
        return {"success": true, "image": image};

      case 'screenshot_element':
        final key = args['key'] as String? ?? args['text'] as String?;
        if (key == null) return {"error": "Element key or text required"};
        final image = await cdp.takeElementScreenshot(key);
        if (image == null) return {"error": "Screenshot failed"};
        return {"image": image};

      case 'scroll_to':
        return await cdp.scrollTo(key: args['key'], text: args['text']);

      case 'go_back':
        final success = await cdp.goBack();
        return success ? "Navigated back" : "Cannot go back";

      case 'get_current_route':
        return await cdp.getCurrentRoute();

      case 'get_navigation_stack':
        return await cdp.getNavigationStack();

      case 'swipe':
        final distance = (args['distance'] ?? 300).toDouble();
        final success = await cdp.swipe(direction: args['direction'], distance: distance, key: args['key']);
        return success ? "Swiped ${args['direction']}" : "Swipe failed";

      case 'long_press':
        final duration = args['duration'] ?? 500;
        final success = await cdp.longPress(key: args['key'], text: args['text'], duration: duration);
        return success ? "Long pressed" : "Long press failed";

      case 'double_tap':
        final success = await cdp.doubleTap(key: args['key'], text: args['text']);
        return success ? "Double tapped" : "Double tap failed";

      case 'wait_for_element':
        final timeout = args['timeout'] ?? 5000;
        final found = await cdp.waitForElement(key: args['key'], text: args['text'], timeout: timeout);
        return {"found": found};

      case 'wait_for_gone':
        final timeout = args['timeout'] ?? 5000;
        final gone = await cdp.waitForGone(key: args['key'], text: args['text'], timeout: timeout);
        return {"gone": gone};

      case 'assert_visible':
        final timeout = args['timeout'] ?? 5000;
        final found = await cdp.waitForElement(key: args['key'], text: args['text'], timeout: timeout);
        return {"success": found, "assertion": "visible", "element": args['key'] ?? args['text']};

      case 'assert_not_visible':
        final timeout = args['timeout'] ?? 5000;
        final gone = await cdp.waitForGone(key: args['key'], text: args['text'], timeout: timeout);
        return {"success": gone, "assertion": "not_visible", "element": args['key'] ?? args['text']};

      case 'get_text_content':
        return await cdp.getTextContent();

      case 'get_text_value':
        return await cdp.getTextValue(args['key']);

      case 'hot_reload':
        await cdp.hotReload();
        return "Page reloaded";

      case 'get_logs':
        return {"logs": [], "summary": {"total_count": 0, "message": "CDP log capture not available"}};

      case 'get_errors':
        return {"errors": [], "summary": {"total_count": 0, "message": "CDP error capture not available"}};

      case 'clear_logs':
        return {"success": true, "message": "No-op for CDP"};

      case 'drag':
        final startX = (args['startX'] as num?)?.toDouble() ?? 0;
        final startY = (args['startY'] as num?)?.toDouble() ?? 0;
        final endX = (args['endX'] as num?)?.toDouble() ?? 0;
        final endY = (args['endY'] as num?)?.toDouble() ?? 0;
        return await cdp.drag(startX, startY, endX, endY);

      case 'tap_at':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        await cdp.tapAt(x, y);
        return {"success": true, "position": {"x": x, "y": y}};

      case 'long_press_at':
        final x = (args['x'] as num).toDouble();
        final y = (args['y'] as num).toDouble();
        await cdp.longPressAt(x, y);
        return {"success": true, "position": {"x": x, "y": y}};

      case 'swipe_coordinates':
        final startX = (args['startX'] ?? args['start_x'] as num?)?.toDouble() ?? 0;
        final startY = (args['startY'] ?? args['start_y'] as num?)?.toDouble() ?? 0;
        final endX = (args['endX'] ?? args['end_x'] as num?)?.toDouble() ?? 0;
        final endY = (args['endY'] ?? args['end_y'] as num?)?.toDouble() ?? 0;
        return await cdp.swipeCoordinates(startX, startY, endX, endY);

      case 'edge_swipe':
        final direction = args['direction'] as String? ?? 'right';
        final edge = args['edge'] as String? ?? 'left';
        final distance = (args['distance'] as num?)?.toInt() ?? 200;
        return await cdp.edgeSwipe(direction, edge: edge, distance: distance);

      case 'gesture':
        final points = ((args['points'] ?? args['actions']) as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
        return await cdp.gesture(points);

      case 'scroll_until_visible':
        final key = args['key'] as String? ?? '';
        final maxScrolls = (args['max_scrolls'] as num?)?.toInt() ?? 10;
        final direction = args['direction'] as String? ?? 'down';
        return await cdp.scrollUntilVisible(key, maxScrolls: maxScrolls, direction: direction);

      case 'get_checkbox_state':
        final key = args['key'] as String? ?? '';
        return await cdp.getCheckboxState(key);

      case 'get_slider_value':
        final key = args['key'] as String? ?? '';
        return await cdp.getSliderValue(key);

      case 'get_page_state':
        return await cdp.getPageState();

      case 'get_interactable_elements':
        return await cdp.getInteractableElements();

      case 'get_performance':
        return await cdp.getPerformance();

      case 'get_frame_stats':
        return await cdp.getFrameStats();

      case 'get_memory_stats':
        return await cdp.getMemoryStats();

      case 'assert_text':
        final text = args['text'] as String? ?? '';
        final key = args['key'] as String?;
        return await cdp.assertText(text, key: key);

      case 'assert_element_count':
        final selector = args['selector'] as String? ?? args['key'] as String? ?? '*';
        final count = (args['expected_count'] as num?)?.toInt() ?? 0;
        return await cdp.assertElementCount(selector, count);

      case 'wait_for_idle':
        final timeoutMs = (args['timeout'] as num?)?.toInt() ?? 5000;
        return await cdp.waitForIdle(timeoutMs: timeoutMs);

      case 'diagnose':
        return await cdp.diagnose();

      case 'execute_batch':
        final actions = args['actions'] as List<dynamic>? ?? [];
        final results = <Map<String, dynamic>>[];
        for (final action in actions) {
          final a = action as Map<String, dynamic>;
          final actionName = (a['action'] ?? a['tool'] ?? a['name']) as String;
          final actionArgs = (a['args'] ?? a['arguments'] ?? a['params']) as Map<String, dynamic>? ?? {};
          try {
            final r = await _executeCdpTool(actionName, actionArgs, cdp);
            results.add({"action": actionName, "success": true, "result": r});
          } catch (e) {
            results.add({"action": actionName, "success": false, "error": e.toString()});
          }
        }
        return {"success": true, "results": results};

      case 'enable_test_indicators':
      case 'get_indicator_status':
        return {"success": true, "message": "No-op for CDP", "enabled": false};

      case 'enable_network_monitoring':
        return {"success": true, "message": "Network monitoring (no-op for CDP)"};

      case 'clear_network_requests':
        return {"success": true, "message": "No-op for CDP"};

      case 'eval':
        final expression = args['expression'] as String? ?? '';
        final result = await cdp.eval(expression);
        return result;

      case 'press_key':
        final key = args['key'] as String? ?? 'Enter';
        final modifiers = (args['modifiers'] as List<dynamic>?)?.cast<String>();
        await cdp.pressKey(key, modifiers: modifiers);
        return {"success": true, "key": key};

      case 'type_text':
        final text = args['text'] as String? ?? '';
        await cdp.typeText(text);
        return {"success": true, "text": text};

      case 'hover':
        return await cdp.hover(key: args['key'], text: args['text'], ref: args['ref']);

      case 'select_option':
        final key = args['key'] as String? ?? '';
        final value = args['value'] as String? ?? '';
        return await cdp.selectOption(key, value);

      case 'set_checkbox':
        final key = args['key'] as String? ?? '';
        final checked = args['checked'] ?? true;
        return await cdp.setCheckbox(key, checked);

      case 'fill':
        final key = args['key'] as String? ?? '';
        final value = args['value'] ?? args['text'] as String? ?? '';
        return await cdp.fill(key, value);

      case 'get_cookies':
        return await cdp.getCookies();

      case 'set_cookie':
        return await cdp.setCookie(
          args['name'] as String? ?? '',
          args['value'] as String? ?? '',
          domain: args['domain'] as String?,
          path: args['path'] as String?,
        );

      case 'clear_cookies':
        return await cdp.clearCookies();

      case 'get_local_storage':
        return await cdp.getLocalStorage();

      case 'set_local_storage':
        return await cdp.setLocalStorage(args['key'] as String? ?? '', args['value'] as String? ?? '');

      case 'clear_local_storage':
        return await cdp.clearLocalStorage();

      case 'get_console_messages':
        return await cdp.getConsoleMessages();

      case 'get_network_requests':
        return await cdp.getNetworkRequests();

      case 'set_viewport':
        return await cdp.setViewport(
          (args['width'] as num?)?.toInt() ?? 1280,
          (args['height'] as num?)?.toInt() ?? 720,
          deviceScaleFactor: (args['device_scale_factor'] as num?)?.toDouble() ?? 1.0,
        );

      case 'emulate_device':
        return await cdp.emulateDevice(args['device'] as String? ?? '');

      case 'generate_pdf':
        return await cdp.generatePdf();

      case 'navigate':
        return await cdp.navigate(args['url'] as String? ?? '');

      case 'go_forward':
        await cdp.goForward();
        return {"success": true};

      case 'reload':
        return await cdp.reload();

      case 'get_attribute':
        return await cdp.getAttribute(args['key'] as String? ?? '', args['attribute'] as String? ?? '');

      case 'get_css_property':
        return await cdp.getCssProperty(args['key'] as String? ?? '', args['property'] as String? ?? '');

      case 'get_bounding_box':
        return await cdp.getBoundingBox(args['key'] as String? ?? '');

      case 'focus':
        return await cdp.focus(args['key'] as String? ?? '');

      case 'blur':
        return await cdp.blur(args['key'] as String? ?? '');

      case 'get_title':
        return {"title": await cdp.getTitle()};

      case 'set_geolocation':
        return await cdp.setGeolocation(
          (args['latitude'] as num?)?.toDouble() ?? 0,
          (args['longitude'] as num?)?.toDouble() ?? 0,
        );

      case 'set_timezone':
        return await cdp.setTimezone(args['timezone'] as String? ?? 'UTC');

      case 'set_color_scheme':
        return await cdp.setColorScheme(args['scheme'] as String? ?? 'dark');

      case 'block_urls':
        return await cdp.blockUrls((args['patterns'] as List<dynamic>?)?.cast<String>() ?? []);

      case 'throttle_network':
        return await cdp.throttleNetwork(
          latencyMs: (args['latency_ms'] as num?)?.toInt() ?? 0,
          downloadKbps: (args['download_kbps'] as num?)?.toInt() ?? -1,
          uploadKbps: (args['upload_kbps'] as num?)?.toInt() ?? -1,
        );

      case 'go_offline':
        return await cdp.goOffline();

      case 'clear_browser_data':
        return await cdp.clearBrowserData();

      case 'upload_file':
        final selector = args['selector'] as String? ?? 'input[type="file"]';
        final files = (args['files'] as List<dynamic>?)?.cast<String>() ?? [];
        return await cdp.uploadFile(selector, files);

      case 'handle_dialog':
        final accept = args['accept'] ?? true;
        final promptText = args['prompt_text'] as String?;
        return await cdp.handleDialog(accept, promptText: promptText);

      case 'get_frames':
        return await cdp.getFrames();

      case 'eval_in_frame':
        return await cdp.evalInFrame(args['frame_id'] as String? ?? '', args['expression'] as String? ?? '');

      case 'get_tabs':
        return await cdp.getTabs();

      case 'new_tab':
        return await cdp.newTab(args['url'] as String? ?? 'about:blank');

      case 'close_tab':
        return await cdp.closeTab(args['target_id'] as String? ?? '');

      case 'switch_tab':
        return await cdp.switchTab(args['target_id'] as String? ?? '');

      case 'intercept_requests':
        return await cdp.interceptRequests(
          args['url_pattern'] as String? ?? '*',
          statusCode: (args['status_code'] as num?)?.toInt(),
          body: args['body'] as String?,
          headers: (args['headers'] as Map<String, dynamic>?)?.cast<String, String>(),
        );

      case 'clear_interceptions':
        return await cdp.clearInterceptions();

      case 'accessibility_audit':
        return await cdp.accessibilityAudit();

      case 'compare_screenshot':
        return await cdp.compareScreenshot(args['baseline_path'] as String? ?? '');

      case 'wait_for_network_idle':
        return await cdp.waitForNetworkIdle(
          timeoutMs: (args['timeout_ms'] as num?)?.toInt() ?? 10000,
          idleMs: (args['idle_ms'] as num?)?.toInt() ?? 500,
        );

      case 'get_session_storage':
        return await cdp.getSessionStorage();

      case 'count_elements':
        final selector = args['selector'] as String? ?? '*';
        return {"count": await cdp.countElements(selector), "selector": selector};

      case 'is_visible':
        final key = args['key'] as String? ?? '';
        return {"visible": await cdp.isVisible(key), "key": key};

      case 'get_page_source':
        return {"source": await cdp.getPageSource(
          selector: args['selector'] as String?,
          removeScripts: args['remove_scripts'] == true,
          removeStyles: args['remove_styles'] == true,
          removeComments: args['remove_comments'] == true,
          removeMeta: args['remove_meta'] == true,
          minify: args['minify'] == true,
          cleanHtml: args['clean_html'] == true,
        )};

      case 'get_visible_text':
        return {"text": await cdp.getVisibleText(selector: args['selector'] as String?)};

      case 'get_window_handles':
        return await cdp.getWindowHandles();

      case 'install_dialog_handler':
        final autoAccept = args['auto_accept'] ?? true;
        await cdp.installDialogHandler(autoAccept: autoAccept);
        return {"success": true, "auto_accept": autoAccept};

      case 'wait_for_navigation':
        return await cdp.waitForNavigation(
          timeoutMs: (args['timeout_ms'] as num?)?.toInt() ?? 30000,
        );

      default:
        throw Exception('Tool "$name" is not supported in CDP mode.');
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
      final actionName = (action['action'] ?? action['tool'] ?? action['name']) as String;
      // Merge nested args into action for backward compatibility
      final actionArgs = action['args'] as Map<String, dynamic>?;
      if (actionArgs != null) {
        for (final e in actionArgs.entries) {
          action.putIfAbsent(e.key, () => e.value);
        }
      }
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

  /// Detect if iOS simulator or Android emulator is running
    /// Find adb binary, checking ANDROID_HOME and common paths
  String _findAdb() {
    final androidHome = Platform.environment['ANDROID_HOME'] ?? 
                        Platform.environment['ANDROID_SDK_ROOT'] ??
                        '${Platform.environment['HOME']}/Library/Android/sdk';
    final adbPath = '$androidHome/platform-tools/adb';
    if (File(adbPath).existsSync()) return adbPath;
    return 'adb'; // fallback to PATH
  }

  Future<String> _detectSimulatorPlatform() async {
    // Check if active session is a bridge connection (non-Flutter)
    final client = _getClient({});
    if (client is BridgeDriver) {
      final fw = client.frameworkName.toLowerCase();
      if (['electron', 'tauri', 'web', 'kmp'].contains(fw)) return 'web';
      if (fw.contains('android') || fw == 'react-native' || fw == 'dotnet-maui') return 'android';
      if (fw.contains('ios')) return 'ios';
      return fw;
    }
    try {
      final result = await Process.run('xcrun', ['simctl', 'list', 'devices', 'booted']);
      if (result.exitCode == 0 && result.stdout.toString().contains('Booted')) {
        return 'ios';
      }
    } catch (_) {}
    return 'android';
  }

  /// Generate TOTP code (RFC 6238)
  String _generateTotp(String secret, int digits, int period) {
    final time = DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ period;
    final timeBytes = ByteData(8)..setInt64(0, time);
    final key = _base32Decode(secret);
    final hmac = Hmac(sha1, key);
    final hash = hmac.convert(timeBytes.buffer.asUint8List()).bytes;
    final offset = hash.last & 0x0f;
    final code = ((hash[offset] & 0x7f) << 24 |
            (hash[offset + 1] & 0xff) << 16 |
            (hash[offset + 2] & 0xff) << 8 |
            (hash[offset + 3] & 0xff)) %
        _pow(10, digits);
    return code.toString().padLeft(digits, '0');
  }

  int _pow(int base, int exp) {
    int result = 1;
    for (var i = 0; i < exp; i++) result *= base;
    return result;
  }

  List<int> _base32Decode(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final cleaned = input.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
    final output = <int>[];
    int buffer = 0, bitsLeft = 0;
    for (final c in cleaned.codeUnits) {
      final val = alphabet.indexOf(String.fromCharCode(c));
      if (val < 0) continue;
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        output.add((buffer >> bitsLeft) & 0xff);
      }
    }
    return output;
  }

  /// Export recorded steps as Jest test
  String _exportJest() {
    final buf = StringBuffer();
    buf.writeln("const { FlutterSkill } = require('flutter-skill');");
    buf.writeln("");
    buf.writeln("describe('Recorded Test', () => {");
    buf.writeln("  let skill;");
    buf.writeln("");
    buf.writeln("  beforeAll(async () => {");
    buf.writeln("    skill = new FlutterSkill();");
    buf.writeln("    await skill.connect();");
    buf.writeln("  });");
    buf.writeln("");
    buf.writeln("  afterAll(async () => { await skill.disconnect(); });");
    buf.writeln("");
    buf.writeln("  test('recorded flow', async () => {");
    for (final step in _recordedSteps) {
      final tool = step['tool'];
      final params = step['params'] as Map<String, dynamic>? ?? {};
      buf.writeln("    await skill.$tool(${jsonEncode(params)});");
    }
    buf.writeln("  });");
    buf.writeln("});");
    return buf.toString();
  }

  /// Export recorded steps as pytest
  String _exportPytest() {
    final buf = StringBuffer();
    buf.writeln("import subprocess");
    buf.writeln("import json");
    buf.writeln("");
    buf.writeln("def call_tool(name, params):");
    buf.writeln("    # Implement MCP tool call via your preferred method");
    buf.writeln("    pass");
    buf.writeln("");
    buf.writeln("def test_recorded_flow():");
    for (final step in _recordedSteps) {
      buf.writeln("    call_tool('${step['tool']}', ${jsonEncode(step['params'] ?? {})})");
    }
    return buf.toString();
  }

  /// Export recorded steps as Dart test
  String _exportDartTest() {
    final buf = StringBuffer();
    buf.writeln("import 'package:test/test.dart';");
    buf.writeln("");
    buf.writeln("void main() {");
    buf.writeln("  test('recorded flow', () async {");
    for (final step in _recordedSteps) {
      final tool = step['tool'];
      final params = step['params'] as Map<String, dynamic>? ?? {};
      buf.writeln("    await driver.$tool(${jsonEncode(params)});");
    }
    buf.writeln("  });");
    buf.writeln("}");
    return buf.toString();
  }

  /// Export recorded steps as Playwright test
  String _exportPlaywright() {
    final buf = StringBuffer();
    buf.writeln("const { test, expect } = require('@playwright/test');");
    buf.writeln("");
    buf.writeln("test('recorded test', async ({ page }) => {");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      final selector = key != null ? '[data-testid="$key"]' : null;
      switch (tool) {
        case 'tap':
          if (selector != null) {
            buf.writeln("  await page.click('$selector');");
          } else if (text != null) {
            buf.writeln("  await page.click('text=$text');");
          }
          break;
        case 'enter_text':
          final value = params['value'] as String? ?? params['text'] as String? ?? '';
          if (selector != null) {
            buf.writeln("  await page.fill('$selector', '${_escapeJs(value)}');");
          }
          break;
        case 'swipe':
          buf.writeln("  // swipe: ${jsonEncode(params)}");
          break;
        case 'screenshot':
          buf.writeln("  await page.screenshot({ path: 'screenshot.png' });");
          break;
        case 'scroll':
          final dx = params['dx'] ?? 0;
          final dy = params['dy'] ?? 0;
          buf.writeln("  await page.mouse.wheel($dx, $dy);");
          break;
        default:
          buf.writeln("  // $tool: ${jsonEncode(params)}");
      }
    }
    buf.writeln("});");
    return buf.toString();
  }

  /// Export recorded steps as Cypress test
  String _exportCypress() {
    final buf = StringBuffer();
    buf.writeln("describe('recorded test', () => {");
    buf.writeln("  it('should complete flow', () => {");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      final selector = key != null ? '[data-testid="$key"]' : null;
      switch (tool) {
        case 'tap':
          if (selector != null) {
            buf.writeln("    cy.get('$selector').click();");
          } else if (text != null) {
            buf.writeln("    cy.contains('$text').click();");
          }
          break;
        case 'enter_text':
          final value = params['value'] as String? ?? params['text'] as String? ?? '';
          if (selector != null) {
            buf.writeln("    cy.get('$selector').type('${_escapeJs(value)}');");
          }
          break;
        case 'swipe':
          buf.writeln("    // swipe: ${jsonEncode(params)}");
          break;
        case 'screenshot':
          buf.writeln("    cy.screenshot();");
          break;
        case 'scroll':
          final dy = params['dy'] ?? 0;
          buf.writeln("    cy.scrollTo(0, $dy);");
          break;
        default:
          buf.writeln("    // $tool: ${jsonEncode(params)}");
      }
    }
    buf.writeln("  });");
    buf.writeln("});");
    return buf.toString();
  }

  /// Export recorded steps as Selenium (Python) test
  String _exportSelenium() {
    final buf = StringBuffer();
    buf.writeln("from selenium import webdriver");
    buf.writeln("from selenium.webdriver.common.by import By");
    buf.writeln("from selenium.webdriver.common.keys import Keys");
    buf.writeln("");
    buf.writeln("driver = webdriver.Chrome()");
    buf.writeln("");
    buf.writeln("try:");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      final selector = key != null ? '[data-testid="$key"]' : null;
      switch (tool) {
        case 'tap':
          if (selector != null) {
            buf.writeln("    driver.find_element(By.CSS_SELECTOR, '$selector').click()");
          } else if (text != null) {
            buf.writeln("    driver.find_element(By.XPATH, '//*[text()=\"${_escapePy(text)}\"]').click()");
          }
          break;
        case 'enter_text':
          final value = params['value'] as String? ?? params['text'] as String? ?? '';
          if (selector != null) {
            buf.writeln("    el = driver.find_element(By.CSS_SELECTOR, '$selector')");
            buf.writeln("    el.clear()");
            buf.writeln("    el.send_keys('${_escapePy(value)}')");
          }
          break;
        case 'swipe':
          buf.writeln("    # swipe: ${jsonEncode(params)}");
          break;
        case 'screenshot':
          buf.writeln("    driver.save_screenshot('screenshot.png')");
          break;
        case 'scroll':
          final dy = params['dy'] ?? 0;
          buf.writeln("    driver.execute_script('window.scrollBy(0, $dy)')");
          break;
        default:
          buf.writeln("    # $tool: ${jsonEncode(params)}");
      }
    }
    buf.writeln("finally:");
    buf.writeln("    driver.quit()");
    return buf.toString();
  }

  /// Export recorded steps as XCUITest (Swift)
  String _exportXCUITest() {
    final buf = StringBuffer();
    buf.writeln("import XCTest");
    buf.writeln("");
    buf.writeln("class RecordedTest: XCTestCase {");
    buf.writeln("    func testRecordedFlow() {");
    buf.writeln("        let app = XCUIApplication()");
    buf.writeln("        app.launch()");
    buf.writeln("");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      final identifier = key ?? text ?? 'unknown';
      switch (tool) {
        case 'tap':
          buf.writeln('        app.buttons["$identifier"].tap()');
          break;
        case 'enter_text':
          final value = params['value'] as String? ?? params['text'] as String? ?? '';
          buf.writeln('        let ${_swiftVar(identifier)}Field = app.textFields["$identifier"]');
          buf.writeln('        ${_swiftVar(identifier)}Field.tap()');
          buf.writeln('        ${_swiftVar(identifier)}Field.typeText("${_escapeSwift(value)}")');
          break;
        case 'swipe':
          final direction = params['direction'] as String? ?? 'up';
          buf.writeln('        app.swipe${direction[0].toUpperCase()}${direction.substring(1)}()');
          break;
        case 'screenshot':
          buf.writeln('        let screenshot = XCUIScreen.main.screenshot()');
          buf.writeln('        let attachment = XCTAttachment(screenshot: screenshot)');
          buf.writeln('        add(attachment)');
          break;
        default:
          buf.writeln('        // $tool: ${jsonEncode(params)}');
      }
    }
    buf.writeln("    }");
    buf.writeln("}");
    return buf.toString();
  }

  /// Export recorded steps as Espresso (Kotlin)
  String _exportEspresso() {
    final buf = StringBuffer();
    buf.writeln("import androidx.test.ext.junit.runners.AndroidJUnit4");
    buf.writeln("import androidx.test.espresso.Espresso.onView");
    buf.writeln("import androidx.test.espresso.action.ViewActions.*");
    buf.writeln("import androidx.test.espresso.matcher.ViewMatchers.*");
    buf.writeln("import org.junit.Test");
    buf.writeln("import org.junit.runner.RunWith");
    buf.writeln("");
    buf.writeln("@RunWith(AndroidJUnit4::class)");
    buf.writeln("class RecordedTest {");
    buf.writeln("    @Test");
    buf.writeln("    fun testRecordedFlow() {");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      switch (tool) {
        case 'tap':
          if (key != null) {
            buf.writeln('        onView(withContentDescription("$key")).perform(click())');
          } else if (text != null) {
            buf.writeln('        onView(withText("$text")).perform(click())');
          }
          break;
        case 'enter_text':
          final value = params['value'] as String? ?? params['text'] as String? ?? '';
          if (key != null) {
            buf.writeln('        onView(withContentDescription("$key")).perform(replaceText("${_escapeKotlin(value)}"))');
          }
          break;
        case 'swipe':
          final direction = params['direction'] as String? ?? 'up';
          buf.writeln('        onView(withId(android.R.id.content)).perform(swipe${direction[0].toUpperCase()}${direction.substring(1)}())');
          break;
        case 'screenshot':
          buf.writeln('        // Take screenshot via UiAutomator or test rule');
          break;
        default:
          buf.writeln('        // $tool: ${jsonEncode(params)}');
      }
    }
    buf.writeln("    }");
    buf.writeln("}");
    return buf.toString();
  }

  String _escapeJs(String s) => s.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
  String _escapePy(String s) => s.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
  String _escapeSwift(String s) => s.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  String _escapeKotlin(String s) => s.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  String _swiftVar(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
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
