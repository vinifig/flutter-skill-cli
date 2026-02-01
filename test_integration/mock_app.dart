import 'dart:convert';
import 'dart:io';

// Mock App that simulates VM Service + Flutter Skill Extensions
// Does NOT depend on vm_service package to avoid version conflicts in this script,
// just handles raw WebSocket JSON-RPC 2.0.

void main(List<String> args) async {
  // 1. Start HTTP Server
  final server = await HttpServer.bind('127.0.0.1', 0);
  final port = server.port;
  final wsUri = 'ws://127.0.0.1:$port/ws';

  // 2. Print the magic line that launch.dart looks for
  print(
    'The Flutter DevTools ... available at: http://127.0.0.1:$port?uri=$wsUri',
  );

  // 3. Listen for WebSocket connections
  server.listen((HttpRequest request) async {
    if (request.uri.path == '/ws') {
      final socket = await WebSocketTransformer.upgrade(request);
      print('MOCK: Client connected');
      _handleConnection(socket);
    }
  });

  print('Mock App Running on $wsUri');
}

void _handleConnection(WebSocket socket) {
  socket.listen(
    (data) {
      if (data is String) {
        final request = jsonDecode(data);
        _processRequest(socket, request);
      }
    },
    onDone: () {
      print('MOCK: Client disconnected');
    },
    onError: (e) {
      print('MOCK: Client error $e');
    },
  );
}

void _processRequest(WebSocket socket, Map<String, dynamic> request) {
  final id = request['id'];
  final method = request['method'];
  print('MOCK_REQ: $method ($id)');

  if (method == 'getVersion') {
    _sendResult(socket, id, {"type": "Version", "major": 3, "minor": 0});
  } else if (method == 'getVM') {
    _sendResult(socket, id, {
      "type": "VM",
      "name": "mock_vm",
      "architectureBits": 64,
      "hostCPU": "MockCPU",
      "operatingSystem": "macos",
      "targetCPU": "x64",
      "version": "3.0.0",
      "pid": 12345,
      "startTime": 0,
      "isolates": [
        {
          "type": "@Isolate",
          "id": "isolates/123",
          "name": "main",
          "number": "123456",
          "isSystemIsolate": false,
        },
      ],
    });
  } else if (method == 'streamListen') {
    _sendResult(socket, id, {"type": "Success"});
  } else if (method == 'callServiceExtension') {
    _handleExtension(socket, id, request['params']);
  } else if (method.startsWith('ext.')) {
    // Direct extension call
    _handleExtension(socket, id, {'method': method, 'args': request['params']});
  } else {
    // Generic success for other calls (getIsolate, etc)
    if (method == 'getIsolate') {
      _sendResult(socket, id, {
        "type": "Isolate",
        "id": "isolates/123",
        "name": "main",
        "number": "123456",
        "startTime": 0,
        "runnable": true,
        "livePorts": 0,
        "pauseOnExit": false,
        "pauseEvent": {"type": "Event", "kind": "Resume", "timestamp": 0},
        "libraries": [],
        "breakpoints": [],
        "exceptionPauseMode": "None",
      });
      return;
    }
    _sendResult(socket, id, {"type": "Success"});
  }
}

void _handleExtension(
  WebSocket socket,
  dynamic id,
  Map<String, dynamic> params,
) {
  final method = params['method'];
  final extArgs = params['args'] ?? {};

  print('MOCK_EXT: $method args=$extArgs');

  if (method == 'ext.flutter.flutter_skill.interactive') {
    _sendResult(socket, id, {
      "elements": [
        {"key": "login_btn", "text": "Login", "type": "ElevatedButton"},
        {"key": "email_field", "text": "", "type": "TextField"},
      ],
    });
  } else if (method == 'ext.flutter.flutter_skill.tap') {
    print('MOCK_APP_LOG: Tapped ${extArgs['key'] ?? extArgs['text']}');
    _sendResult(socket, id, {
      "success": true,
      "message": "Tap successful",
      "target": {"key": extArgs['key'], "text": extArgs['text']},
      "position": {"x": 100, "y": 200},
    });
  } else if (method == 'ext.flutter.flutter_skill.enterText') {
    print(
      'MOCK_APP_LOG: Entered text "${extArgs['text']}" into ${extArgs['key']}',
    );
    _sendResult(socket, id, {
      "success": true,
      "message": "Text entered",
      "target": {"key": extArgs['key']},
    });
  } else if (method == 'ext.flutter.inspector.getRootWidgetSummaryTree') {
    _sendResult(socket, id, {
      "description": "MockRoot",
      "children": [
        {
          "description": "Column",
          "children": [
            {"description": "Text"},
          ],
        },
      ],
    });
  } else {
    _sendResult(socket, id, {"type": "Success"});
  }
}

void _sendResult(WebSocket socket, dynamic id, dynamic result) {
  if (id == null) return;
  socket.add(jsonEncode({"jsonrpc": "2.0", "id": id, "result": result}));
}
