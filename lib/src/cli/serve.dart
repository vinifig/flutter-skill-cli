import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/cdp_driver.dart';

/// `flutter-skill serve` — Zero-config WebMCP server.
///
/// Connects to any running app/website via CDP and exposes
/// all interactive UI elements as MCP tools. Supports hot reload
/// detection — when the page changes, tools auto-update.
///
/// Usage:
///   flutter-skill serve --url=https://example.com
///   flutter-skill serve --cdp-port=9222 --no-launch
///   flutter-skill serve --url=https://example.com --port=3000 --headless
Future<void> runServe(List<String> args) async {
  String url = 'about:blank';
  int cdpPort = 9222;
  int serverPort = 3000;
  bool headless = false;
  bool launchChrome = true;
  bool watch = true;

  for (final arg in args) {
    if (arg.startsWith('--url=')) {
      url = arg.substring(6);
    } else if (arg.startsWith('--cdp-port=')) {
      cdpPort = int.parse(arg.substring(11));
    } else if (arg.startsWith('--port=')) {
      serverPort = int.parse(arg.substring(7));
    } else if (arg == '--headless') {
      headless = true;
    } else if (arg == '--no-launch') {
      launchChrome = false;
    } else if (arg == '--no-watch') {
      watch = false;
    } else if (!arg.startsWith('-')) {
      // Positional arg = URL
      url = arg;
    }
  }

  if (url == 'about:blank' && launchChrome) {
    print('Usage: flutter-skill serve <url>');
    print('');
    print('Examples:');
    print('  flutter-skill serve https://example.com');
    print('  flutter-skill serve https://amazon.com --port=3000');
    print('  flutter-skill serve --cdp-port=9222 --no-launch');
    print('  flutter-skill serve https://app.com --headless');
    print('');
    print('Options:');
    print('  --port=N       HTTP server port (default: 3000)');
    print('  --cdp-port=N   Chrome DevTools port (default: 9222)');
    print('  --headless     Run Chrome in headless mode');
    print('  --no-launch    Connect to existing Chrome instance');
    print('  --no-watch     Disable hot reload detection');
    print('');
    print('This starts a WebMCP-compatible server that auto-discovers');
    print('all interactive elements on the page and exposes them as tools.');
    print('Any MCP client can connect and control the app.');
    exit(1);
  }

  print('🚀 flutter-skill serve — Zero-Config WebMCP');
  print('');
  print('   URL: $url');
  print('   CDP Port: $cdpPort');
  print('   Server Port: $serverPort');
  print('   Headless: $headless');
  print('   Hot Reload Watch: $watch');
  print('');

  // Step 1: Connect via CDP
  print('📡 Connecting to Chrome...');
  final cdp = CdpDriver(
    url: url,
    port: cdpPort,
    launchChrome: launchChrome,
    headless: headless,
  );
  await cdp.connect();
  print('✅ Connected via CDP');

  // Step 2: Initial tool discovery
  print('🔍 Scanning page for interactive elements...');
  var toolCache = await _discoverAndPrint(cdp);

  // Step 3: Set up hot reload detection
  if (watch) {
    print('👀 Watching for changes (HMR / hot reload / DOM mutations)...');
    await _setupHotReloadDetection(cdp);
  }

  // Step 4: Start HTTP server
  print('');
  print('═══════════════════════════════════════════════');
  print('  📋 WebMCP Server: http://localhost:$serverPort');
  print('');
  print('  Endpoints:');
  print('    GET  /tools/list     — List all discovered tools');
  print('    POST /tools/call     — Call a tool { name, arguments }');
  print('    GET  /snapshot       — Page text snapshot');
  print('    GET  /screenshot     — Page screenshot (JPEG)');
  print('    POST /navigate       — Navigate { url }');
  print('    POST /refresh        — Force re-scan tools');
  print('    GET  /health         — Server status');
  print('═══════════════════════════════════════════════');
  print('');
  print('Press Ctrl+C to stop.');

  final server = await HttpServer.bind(InternetAddress.anyIPv4, serverPort);

  // Shared mutable state
  final state = _ServeState(toolCache, DateTime.now());

  // Background: poll for DOM changes
  if (watch) {
    Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final changed = await _checkForChanges(cdp);
        if (changed) {
          print('🔄 Page changed (hot reload?) — rescanning...');
          state.tools = await _discoverAndPrint(cdp);
          state.updatedAt = DateTime.now();
        }
      } catch (e) {
        // CDP connection may drop — ignore
      }
    });
  }

  await for (final request in server) {
    try {
      // Refresh tools on each request if stale (> 30s)
      if (DateTime.now().difference(state.updatedAt).inSeconds > 30) {
        try {
          state.tools = await _discoverTools(cdp);
          state.updatedAt = DateTime.now();
        } catch (e) {
          print('   ⚠️ Tool refresh failed: $e');
        }
      }
      await _handleRequest(request, cdp, state);
    } catch (e) {
      print('   ❌ Request error: $e');
      try {
        request.response
          ..statusCode = 500
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': e.toString()}));
        await request.response.close();
      } catch (_) {}
    }
  }
}

/// Shared mutable state for the serve session
class _ServeState {
  List<Map<String, dynamic>> tools;
  DateTime updatedAt;
  _ServeState(this.tools, this.updatedAt);
}

/// Handle HTTP requests
Future<void> _handleRequest(
  HttpRequest request,
  CdpDriver cdp,
  _ServeState state,
) async {
  final tools = state.tools;
  final path = request.uri.path;
  final method = request.method;
  final response = request.response;

  // CORS
  response.headers.add('Access-Control-Allow-Origin', '*');
  response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

  if (method == 'OPTIONS') {
    response.statusCode = 200;
    await response.close();
    return;
  }

  switch (path) {
    case '/':
    case '/health':
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'status': 'ok',
          'service': 'flutter-skill-webmcp',
          'version': '0.8.5',
          'tools': tools.length,
          'capabilities': [
            'auto-discover',
            'hot-reload',
            'zero-config',
            'snapshot',
            'screenshot',
          ],
        }));
      await response.close();

    case '/tools/list':
    case '/tools':
      final toolDefs = tools.map(_toMcpToolDef).toList();
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'tools': toolDefs}));
      await response.close();

    case '/tools/call':
      if (method != 'POST') {
        response
          ..statusCode = 405
          ..write('POST required');
        await response.close();
        return;
      }
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      final toolName = body['name'] as String?;
      final toolArgs =
          (body['arguments'] ?? body['params'] ?? {}) as Map<String, dynamic>;

      if (toolName == null) {
        response
          ..statusCode = 400
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': 'Missing "name" field'}));
        await response.close();
        return;
      }

      print('   🔧 Calling tool: $toolName');
      final result = await cdp.callTool(toolName, toolArgs);
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(result));
      await response.close();

    case '/snapshot':
      // Text-based page snapshot (token efficient)
      final result = await cdp.call('Runtime.evaluate', {
        'expression': _snapshotJs,
        'returnByValue': true,
      });
      final text = result['result']?['value'] as String? ?? '';
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'snapshot': text, 'length': text.length}));
      await response.close();

    case '/screenshot':
      final data = await cdp.takeScreenshot(quality: 0.8, maxWidth: 1280);
      if (data != null) {
        response
          ..statusCode = 200
          ..headers.set('Content-Type', 'image/jpeg')
          ..add(base64Decode(data));
      } else {
        response
          ..statusCode = 500
          ..write('Screenshot failed');
      }
      await response.close();

    case '/navigate':
      if (method != 'POST') {
        response
          ..statusCode = 405
          ..write('POST required');
        await response.close();
        return;
      }
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      final navUrl = body['url'] as String?;
      if (navUrl == null) {
        response
          ..statusCode = 400
          ..write('Missing "url" field');
        await response.close();
        return;
      }
      print('   🌐 Navigating to: $navUrl');
      try {
        // Use CDP Page.navigate directly to stay on same WS connection
        await cdp.call('Page.navigate', {'url': navUrl});
        // Wait for page load
        await Future.delayed(const Duration(seconds: 3));
        // Re-setup observers and re-scan tools
        await _setupHotReloadDetection(cdp);
        state.tools = await _discoverAndPrint(cdp);
        state.updatedAt = DateTime.now();
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
              jsonEncode({'navigated': navUrl, 'tools': state.tools.length}));
      } catch (e) {
        response
          ..statusCode = 500
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': e.toString()}));
      }
      await response.close();

    case '/refresh':
      print('   🔄 Force refresh tools');
      state.tools = await _discoverAndPrint(cdp);
      state.updatedAt = DateTime.now();
      response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'tools': state.tools.length, 'refreshed': true}));
      await response.close();

    default:
      response
        ..statusCode = 404
        ..write('Not found: $path');
      await response.close();
  }
}

/// Convert internal tool format to MCP tool definition
Map<String, dynamic> _toMcpToolDef(Map<String, dynamic> tool) {
  final params = tool['params'] as Map<String, dynamic>? ?? {};
  final properties = <String, dynamic>{};
  final required = <String>[];

  params.forEach((key, value) {
    if (value is Map<String, dynamic>) {
      properties[key] = {
        'type': value['type'] ?? 'string',
        'description': value['description'] ?? '',
      };
      if (value['required'] == true) required.add(key);
    }
  });

  return {
    'name': tool['name'],
    'description': tool['description'] ?? '',
    'inputSchema': {
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
    },
  };
}

/// Discover tools and print summary
Future<List<Map<String, dynamic>>> _discoverAndPrint(CdpDriver cdp) async {
  final tools = await _discoverTools(cdp);

  // Group by source
  final bySource = <String, int>{};
  for (final t in tools) {
    final source = t['source'] as String? ?? 'unknown';
    bySource[source] = (bySource[source] ?? 0) + 1;
  }

  print('   📦 ${tools.length} tools discovered:');
  bySource.forEach((source, count) {
    final icon = switch (source) {
      'auto-ui' => '🔍 UI elements',
      'auto-form' => '📝 Forms',
      'js-registered' => '📦 JS registered',
      'data-mcp-tool' => '🏷️ Annotated',
      'well-known' => '🌐 .well-known',
      'link-manifest' => '🔗 Manifest',
      _ => '❓ $source',
    };
    print('      $icon: $count');
  });

  return tools;
}

/// Raw tool discovery
Future<List<Map<String, dynamic>>> _discoverTools(CdpDriver cdp) async {
  final result = await cdp.discoverTools();
  return (result['tools'] as List?)?.cast<Map<String, dynamic>>() ?? [];
}

/// Set up hot reload / HMR / DOM mutation detection
Future<void> _setupHotReloadDetection(CdpDriver cdp) async {
  await cdp.call('Runtime.evaluate', {
    'expression': '''
    (() => {
      if (window.__fs_serve_observer__) return 'already active';

      window.__fs_dom_change_count__ = 0;
      window.__fs_last_checked__ = 0;

      // 1. DOM MutationObserver — catches all framework renders
      const observer = new MutationObserver((mutations) => {
        const significant = mutations.some(m =>
          m.type === 'childList' && (m.addedNodes.length > 0 || m.removedNodes.length > 0)
        );
        if (significant) window.__fs_dom_change_count__++;
      });
      observer.observe(document.body || document.documentElement, {
        childList: true,
        subtree: true,
      });
      window.__fs_serve_observer__ = observer;

      // 2. Navigation events
      window.addEventListener('popstate', () => window.__fs_dom_change_count__++);
      window.addEventListener('hashchange', () => window.__fs_dom_change_count__++);

      // 3. Vite HMR
      try {
        if (import.meta?.hot) {
          import.meta.hot.on('vite:afterUpdate', () => window.__fs_dom_change_count__ += 10);
          import.meta.hot.on('vite:fullReload', () => window.__fs_dom_change_count__ += 10);
        }
      } catch(e) {}

      // 4. Webpack HMR
      try {
        if (module?.hot) {
          module.hot.addStatusHandler((status) => {
            if (status === 'apply') window.__fs_dom_change_count__ += 10;
          });
        }
      } catch(e) {}

      // 5. React Fast Refresh (detect re-renders)
      // React DevTools hook fires on commit
      try {
        if (window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
          const orig = window.__REACT_DEVTOOLS_GLOBAL_HOOK__.onCommitFiberRoot;
          if (orig) {
            window.__REACT_DEVTOOLS_GLOBAL_HOOK__.onCommitFiberRoot = function(...args) {
              window.__fs_dom_change_count__++;
              return orig.apply(this, args);
            };
          }
        }
      } catch(e) {}

      // 6. Flutter Web hot reload (service worker message)
      try {
        navigator.serviceWorker?.addEventListener('message', (e) => {
          if (e.data?.type === 'FLUTTER_REASSEMBLE') {
            window.__fs_dom_change_count__ += 10;
          }
        });
      } catch(e) {}

      return 'observers installed';
    })()
    ''',
    'returnByValue': true,
  });
}

/// Check if page changed since last check
Future<bool> _checkForChanges(CdpDriver cdp) async {
  final result = await cdp.call('Runtime.evaluate', {
    'expression': '''
    (() => {
      const c = window.__fs_dom_change_count__ || 0;
      const last = window.__fs_last_checked__ || 0;
      window.__fs_last_checked__ = c;
      return c > last;
    })()
    ''',
    'returnByValue': true,
  });
  return result['result']?['value'] == true;
}

/// JS for text-based page snapshot
const _snapshotJs = '''
(() => {
  const lines = [];
  const walk = (node, depth) => {
    if (node.nodeType === 3) {
      const t = node.textContent.trim();
      if (t) lines.push('  '.repeat(depth) + t);
      return;
    }
    if (node.nodeType !== 1) return;
    const el = node;
    const tag = el.tagName.toLowerCase();
    if (['script','style','noscript','svg','path'].includes(tag)) return;
    if (el.hidden || el.style.display === 'none') return;

    const role = el.getAttribute('role') || '';
    const label = el.getAttribute('aria-label') || '';
    const href = el.getAttribute('href') || '';

    let prefix = '';
    if (tag === 'button' || role === 'button') prefix = '[button] ';
    else if (tag === 'a' && href) prefix = '[link] ';
    else if (tag === 'input') prefix = '[input:' + (el.type||'text') + '] ';
    else if (tag === 'textarea') prefix = '[textarea] ';
    else if (tag === 'select') prefix = '[select] ';
    else if (tag === 'img') { lines.push('  '.repeat(depth) + '[img] ' + (el.alt||'')); return; }
    else if (['h1','h2','h3','h4','h5','h6'].includes(tag)) prefix = '[' + tag + '] ';

    if (prefix && label) {
      lines.push('  '.repeat(depth) + prefix + label);
    }

    for (const child of el.childNodes) walk(child, depth + (prefix ? 1 : 0));
  };
  walk(document.body, 0);
  return lines.join('\\n');
})()
''';
