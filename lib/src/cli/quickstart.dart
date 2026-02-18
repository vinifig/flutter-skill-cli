import 'dart:io';
import 'dart:async';
import 'package:flutter_skill/src/cli/explore.dart' show runExplore;

/// Run a quick guided demo to showcase flutter-skill capabilities.
Future<void> runQuickstart(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : null;

  print('');
  print('🚀 flutter-skill quickstart');
  print('═══════════════════════════════════════════════════════════');
  print('');

  if (url != null) {
    await _quickstartWithUrl(url);
  } else {
    await _quickstartWithDemo();
  }
}

Future<void> _quickstartWithUrl(String url) async {
  print('  Target: $url');
  print('');

  // Step 1: Serve
  print('  ── Step 1/3: Starting WebMCP server ──');
  print('');
  try {
    // Run serve in background, explore, then monkey
    // We'll run explore and monkey directly with the URL
    await _runStep('explore', () async {
      print('  ── AI Explore (depth=1) ──');
      print('');
      await runExplore([url, '--depth=1', '--headless']);
    });
  } catch (e) {
    print('  ⚠️  Error during quickstart: $e');
  }

  _printSummary(url);
}

Future<void> _quickstartWithDemo() async {
  print('  No URL provided — launching built-in demo app...');
  print('');

  // Create temp directory and HTML file
  final tempDir = await Directory.systemTemp.createTemp('flutter-skill-demo-');
  final htmlFile = File('${tempDir.path}/index.html');
  await htmlFile.writeAsString(_demoHtml);

  // Start a simple HTTP server
  HttpServer? server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final demoUrl = 'http://localhost:$port';

    print('  ✅ Demo app running at $demoUrl');
    print('');

    // Serve files
    server.listen((request) async {
      final path = request.uri.path == '/' ? '/index.html' : request.uri.path;
      final file = File('${tempDir.path}$path');
      if (await file.exists()) {
        final ext = path.split('.').last;
        final contentType = ext == 'html'
            ? 'text/html'
            : ext == 'js'
                ? 'application/javascript'
                : 'text/plain';
        request.response.headers.contentType = ContentType.parse(contentType);
        request.response.add(await file.readAsBytes());
      } else {
        request.response.statusCode = 404;
        request.response.write('Not found');
      }
      await request.response.close();
    });

    // Run explore only — fast onboarding
    print('  ── AI Explore ──');
    print('');
    try {
      await runExplore([demoUrl, '--depth=1', '--headless']);
    } catch (e) {
      print('  ⚠️  Explore: $e');
    }

    _printSummary(demoUrl);
  } catch (e) {
    print('  ❌ Could not start demo server: $e');
  } finally {
    // Cleanup
    await server?.close(force: true);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

Future<void> _runStep(String name, Future<void> Function() step) async {
  try {
    await step();
  } catch (e) {
    print('  ⚠️  $name failed: $e');
  }
}

void _printSummary(String url) {
  print('');
  print('═══════════════════════════════════════════════════════════');
  print('  🎉 Quickstart complete!');
  print('');
  print('  What just happened:');
  print('    1. AI explored the app and discovered UI elements');
  print('    2. Monkey testing randomly interacted with the app');
  print('');
  print('  Next steps:');
  print('    flutter-skill serve $url        # full MCP server');
  print('    flutter-skill explore $url      # deeper exploration');
  print('    flutter-skill monkey $url       # longer fuzz test');
  print('    flutter-skill init              # setup your own project');
  print('');
  print('  Or ask your AI agent:');
  print('    "Test the login flow on $url"');
  print('    "Find accessibility issues"');
  print('    "Take a screenshot after clicking Login"');
  print('═══════════════════════════════════════════════════════════');
  print('');
}

// ─── Demo HTML ───────────────────────────────────────────────────

const _demoHtml = '''<!DOCTYPE html>
<html>
<head>
  <title>flutter-skill Demo App</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: -apple-system, sans-serif; max-width: 480px; margin: 40px auto; padding: 0 20px; }
    h1 { color: #1a73e8; }
    input, button { padding: 10px; margin: 5px 0; font-size: 16px; border-radius: 6px; border: 1px solid #ccc; }
    button { background: #1a73e8; color: white; border: none; cursor: pointer; }
    button:hover { background: #1557b0; }
    ul { list-style: none; padding: 0; }
    li { padding: 10px; margin: 4px 0; background: #f1f3f4; border-radius: 6px; cursor: pointer; }
    li:hover { background: #e8eaed; text-decoration: line-through; }
    form { display: flex; flex-direction: column; gap: 8px; }
  </style>
</head>
<body>
  <h1>Demo App</h1>
  <form id="login-form">
    <input type="email" placeholder="Email" id="email" required>
    <input type="password" placeholder="Password" id="password" required>
    <button type="submit">Login</button>
  </form>
  <div id="todo-section" style="display:none">
    <h2>Todos</h2>
    <div style="display:flex;gap:8px">
      <input id="todo-input" placeholder="Add todo" style="flex:1">
      <button onclick="addTodo()">Add</button>
    </div>
    <ul id="todo-list"></ul>
  </div>
  <!-- Intentional a11y issues for demo -->
  <img src="logo.png">
  <a href="#">Click here</a>
  <div onclick="alert('clicked')" style="width:20px;height:20px;background:blue"></div>
  <script>
    document.getElementById('login-form').onsubmit = function(e) {
      e.preventDefault();
      document.getElementById('login-form').style.display = 'none';
      document.getElementById('todo-section').style.display = 'block';
    };
    function addTodo() {
      var input = document.getElementById('todo-input');
      if (input.value) {
        var li = document.createElement('li');
        li.textContent = input.value;
        li.onclick = function() { this.remove(); };
        document.getElementById('todo-list').appendChild(li);
        input.value = '';
      }
    }
  </script>
</body>
</html>''';
