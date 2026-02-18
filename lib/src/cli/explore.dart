import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/cdp_driver.dart';

/// `flutter-skill explore` — AI Test Agent that autonomously explores a web app.
///
/// Usage:
///   flutter-skill explore https://my-app.com [--depth=3] [--report=./report.html]
Future<void> runExplore(List<String> args) async {
  String? url;
  int depth = 3;
  String reportPath = './explore-report.html';
  int cdpPort = 9222;
  bool headless = true;

  for (final arg in args) {
    if (arg.startsWith('--depth=')) {
      depth = int.parse(arg.substring(8));
    } else if (arg.startsWith('--report=')) {
      reportPath = arg.substring(9);
    } else if (arg.startsWith('--cdp-port=')) {
      cdpPort = int.parse(arg.substring(11));
    } else if (arg == '--no-headless') {
      headless = false;
    } else if (!arg.startsWith('-')) {
      url = arg;
    }
  }

  if (url == null) {
    print('Usage: flutter-skill explore <url> [--depth=3] [--report=./report.html]');
    print('');
    print('Options:');
    print('  --depth=N          Max crawl depth (default: 3)');
    print('  --report=PATH      HTML report output path (default: ./explore-report.html)');
    print('  --cdp-port=N       Chrome DevTools port (default: 9222)');
    print('  --no-headless      Run Chrome with UI visible');
    exit(1);
  }

  print('🤖 flutter-skill explore — AI Test Agent');
  print('');
  print('   URL: $url');
  print('   Depth: $depth');
  print('   Report: $reportPath');
  print('   Headless: $headless');
  print('');

  final agent = _ExploreAgent(
    startUrl: url,
    maxDepth: depth,
    reportPath: reportPath,
    cdpPort: cdpPort,
    headless: headless,
  );

  await agent.run();
}

/// Test strings for boundary testing
const _boundaryTestStrings = [
  '', // empty
  ' ', // whitespace only
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', // very long text
  '<script>alert("xss")</script>', // XSS
  "'; DROP TABLE users; --", // SQL injection
  '"><img src=x onerror=alert(1)>', // HTML injection
  '🎉🔥💀', // emoji
  '\x00\x01\x02', // null bytes
  '-1', // negative number
  '0', // zero
  '99999999999999999999', // huge number
];

class _ExploreAgent {
  final String startUrl;
  final int maxDepth;
  final String reportPath;
  final int cdpPort;
  final bool headless;

  late CdpDriver _cdp;

  /// Visited URLs → page results
  final Map<String, _PageResult> _visited = {};

  /// Queue: (url, depth)
  final List<(String, int)> _queue = [];

  /// Console errors collected
  final List<String> _consoleErrors = [];

  _ExploreAgent({
    required this.startUrl,
    required this.maxDepth,
    required this.reportPath,
    required this.cdpPort,
    required this.headless,
  });

  Future<void> run() async {
    // Step 1: Launch Chrome and connect
    print('📡 Launching Chrome and connecting via CDP...');
    _cdp = CdpDriver(
      url: startUrl,
      port: cdpPort,
      launchChrome: true,
      headless: headless,
    );
    await _cdp.connect();
    print('✅ Connected');

    // Step 2: Set up console error monitoring
    await _setupConsoleMonitoring();

    // Step 3: Crawl
    _queue.add((startUrl, 0));

    while (_queue.isNotEmpty) {
      final (pageUrl, currentDepth) = _queue.removeAt(0);
      final normalizedUrl = _normalizeUrl(pageUrl);

      if (_visited.containsKey(normalizedUrl)) continue;
      if (currentDepth > maxDepth) continue;

      print('');
      print('🔍 [$currentDepth/$maxDepth] Exploring: $pageUrl');

      final result = await _explorePage(pageUrl, currentDepth);
      _visited[normalizedUrl] = result;

      // Queue discovered links
      if (currentDepth < maxDepth) {
        for (final link in result.discoveredLinks) {
          final normLink = _normalizeUrl(link);
          if (!_visited.containsKey(normLink) &&
              _isSameOrigin(link, startUrl)) {
            _queue.add((link, currentDepth + 1));
          }
        }
      }
    }

    // Step 4: Disconnect
    await _cdp.disconnect();

    // Step 5: Generate report
    print('');
    print('📊 Generating report...');
    await _generateReport();

    // Summary
    final totalBugs =
        _visited.values.fold<int>(0, (sum, r) => sum + r.bugs.length);
    final totalA11y = _visited.values
        .fold<int>(0, (sum, r) => sum + r.accessibilityIssues.length);
    print('');
    print('═══════════════════════════════════════════════');
    print('  📋 Exploration Complete');
    print('  Pages visited: ${_visited.length}');
    print('  Bugs found: $totalBugs');
    print('  Accessibility issues: $totalA11y');
    print('  Console errors: ${_consoleErrors.length}');
    print('  Report: $reportPath');
    print('═══════════════════════════════════════════════');
  }

  Future<void> _setupConsoleMonitoring() async {
    await _cdp.call('Runtime.enable');
    await _cdp.call('Log.enable');
    // Install JS-side error collector
    await _cdp.evaluate('''
      window.__fs_explore_errors__ = [];
      window.addEventListener('error', (e) => {
        window.__fs_explore_errors__.push({
          type: 'error',
          message: e.message || String(e),
          source: e.filename || '',
          line: e.lineno || 0
        });
      });
      window.addEventListener('unhandledrejection', (e) => {
        window.__fs_explore_errors__.push({
          type: 'unhandledrejection',
          message: e.reason?.message || String(e.reason),
          source: '',
          line: 0
        });
      });
    ''');
  }

  Future<List<String>> _collectErrors() async {
    final result = await _cdp.evaluate('''
      JSON.stringify(window.__fs_explore_errors__ || [])
    ''');
    final v = result['result']?['value'] as String?;
    if (v == null) return [];
    final list = jsonDecode(v) as List;
    // Reset
    await _cdp.evaluate('window.__fs_explore_errors__ = []');
    return list.map((e) => '${e['type']}: ${e['message']}').toList();
  }

  Future<_PageResult> _explorePage(String pageUrl, int currentDepth) async {
    final result = _PageResult(url: pageUrl, depth: currentDepth);

    try {
      // Navigate
      await _cdp.call('Page.navigate', {'url': pageUrl});
      await Future.delayed(const Duration(seconds: 2));

      // Re-install error monitoring after navigation
      await _setupConsoleMonitoring();

      // Take screenshot
      final screenshot = await _cdp.takeScreenshot(quality: 0.8);
      if (screenshot != null) {
        result.screenshotBase64 = screenshot;
      }

      // Discover interactive elements
      final structured = await _cdp.getInteractiveElementsStructured();
      final elements =
          (structured['elements'] as List<dynamic>?) ?? [];
      result.elementCount = elements.length;
      print('   📦 Found ${elements.length} interactive elements');

      // Discover links
      final linksResult = await _cdp.evaluate('''
        JSON.stringify(
          Array.from(document.querySelectorAll('a[href]'))
            .map(a => a.href)
            .filter(h => h && !h.startsWith('javascript:') && !h.startsWith('mailto:'))
        )
      ''');
      final linksJson = linksResult['result']?['value'] as String?;
      if (linksJson != null) {
        result.discoveredLinks =
            (jsonDecode(linksJson) as List).cast<String>();
        print('   🔗 Found ${result.discoveredLinks.length} links');
      }

      // Run accessibility audit
      final a11y = await _cdp.accessibilityAudit();
      final issues = (a11y['issues'] as List?) ?? [];
      result.accessibilityIssues = issues
          .map((i) =>
              '${i['type']}: [${i['rule']}] ${i['message']}')
          .toList();
      if (result.accessibilityIssues.isNotEmpty) {
        print(
            '   ♿ ${result.accessibilityIssues.length} accessibility issues');
      }

      // Test interactions — fill forms, click buttons, test boundaries
      await _testInteractions(elements, result);

      // Collect console errors
      final errors = await _collectErrors();
      if (errors.isNotEmpty) {
        result.bugs.addAll(errors.map((e) => 'Console: $e'));
        _consoleErrors.addAll(errors);
        print('   ⚠️ ${errors.length} console errors');
      }

      // Check for 404/error indicators
      final pageText = await _cdp.getTextContent();
      if (pageText.contains('404') && pageText.contains('not found')) {
        result.bugs.add('Possible 404 page detected');
      }
      if (pageText.contains('Internal Server Error') ||
          pageText.contains('500')) {
        result.bugs.add('Possible 500 error page detected');
      }
    } catch (e) {
      result.bugs.add('Exploration error: $e');
      print('   ❌ Error: $e');
    }

    return result;
  }

  Future<void> _testInteractions(
      List<dynamic> elements, _PageResult result) async {
    int tested = 0;
    for (final el in elements) {
      if (el is! Map<String, dynamic>) continue;
      final actions = (el['actions'] as List?)?.cast<String>() ?? [];
      final ref = el['ref'] as String? ?? '';
      final type = el['type'] as String? ?? '';

      try {
        if (actions.contains('enter_text') &&
            (type == 'input' || type == 'textarea')) {
          // Test boundary inputs on form fields
          for (final testStr in _boundaryTestStrings.take(3)) {
            final key = el['selector'] as String?;
            if (key != null) {
              await _cdp.fill(
                  key.replaceFirst('#', '').replaceAll(RegExp(r'\[.*\]'), ''),
                  testStr);
              await Future.delayed(const Duration(milliseconds: 100));

              // Check for errors after input
              final errors = await _collectErrors();
              if (errors.isNotEmpty) {
                result.bugs.add(
                    'Input "$ref" caused errors with test value "${testStr.length > 20 ? '${testStr.substring(0, 20)}...' : testStr}": ${errors.join(', ')}');
                _consoleErrors.addAll(errors);
              }
            }
          }
          tested++;
        } else if (actions.contains('tap') &&
            (type == 'button' || ref.startsWith('button:'))) {
          // Tap buttons (carefully — don't navigate away from page)
          final text = (el['text'] as String? ?? '').toLowerCase();
          // Skip buttons that might navigate away or submit
          if (!text.contains('submit') &&
              !text.contains('delete') &&
              !text.contains('remove') &&
              !text.contains('logout') &&
              !text.contains('sign out')) {
            await _cdp.tap(ref: ref);
            await Future.delayed(const Duration(milliseconds: 300));

            final errors = await _collectErrors();
            if (errors.isNotEmpty) {
              result.bugs.add(
                  'Button "$ref" click caused errors: ${errors.join(', ')}');
              _consoleErrors.addAll(errors);
            }
            tested++;
          }
        }
      } catch (e) {
        // Interaction failed — not necessarily a bug
      }

      if (tested >= 10) break; // Limit interactions per page
    }
    if (tested > 0) print('   🧪 Tested $tested interactions');
  }

  String _normalizeUrl(String url) {
    try {
      final uri = Uri.parse(url);
      // Remove fragment and trailing slash
      return uri.replace(fragment: '').toString().replaceAll(RegExp(r'/$'), '');
    } catch (_) {
      return url;
    }
  }

  bool _isSameOrigin(String url, String baseUrl) {
    try {
      final uri = Uri.parse(url);
      final base = Uri.parse(baseUrl);
      return uri.host == base.host;
    } catch (_) {
      return false;
    }
  }

  Future<void> _generateReport() async {
    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html lang="en"><head>');
    buffer.writeln('<meta charset="utf-8">');
    buffer.writeln(
        '<meta name="viewport" content="width=device-width, initial-scale=1">');
    buffer.writeln('<title>flutter-skill explore Report</title>');
    buffer.writeln('<style>');
    buffer.writeln('''
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #e2e8f0; padding: 2rem; }
      h1 { font-size: 2rem; margin-bottom: 0.5rem; }
      .summary { display: flex; gap: 1rem; margin: 1.5rem 0; flex-wrap: wrap; }
      .stat { background: #1e293b; border-radius: 12px; padding: 1rem 1.5rem; min-width: 140px; }
      .stat-value { font-size: 2rem; font-weight: bold; }
      .stat-label { font-size: 0.85rem; color: #94a3b8; }
      .stat-value.errors { color: #f87171; }
      .stat-value.warnings { color: #fbbf24; }
      .stat-value.ok { color: #4ade80; }
      .page { background: #1e293b; border-radius: 12px; padding: 1.5rem; margin: 1rem 0; }
      .page-url { font-size: 1.1rem; font-weight: 600; color: #60a5fa; word-break: break-all; }
      .page-meta { font-size: 0.85rem; color: #94a3b8; margin: 0.3rem 0; }
      .bugs { margin-top: 0.75rem; }
      .bug { background: #7f1d1d33; border-left: 3px solid #f87171; padding: 0.5rem 0.75rem; margin: 0.3rem 0; border-radius: 4px; font-size: 0.9rem; }
      .a11y-issue { background: #78350f33; border-left: 3px solid #fbbf24; padding: 0.5rem 0.75rem; margin: 0.3rem 0; border-radius: 4px; font-size: 0.9rem; }
      .screenshot { max-width: 100%; max-height: 300px; border-radius: 8px; margin-top: 0.75rem; border: 1px solid #334155; }
      .section-title { font-size: 1.3rem; margin: 2rem 0 0.5rem; padding-bottom: 0.5rem; border-bottom: 1px solid #334155; }
    ''');
    buffer.writeln('</style></head><body>');

    final totalBugs =
        _visited.values.fold<int>(0, (s, r) => s + r.bugs.length);
    final totalA11y = _visited.values
        .fold<int>(0, (s, r) => s + r.accessibilityIssues.length);

    buffer.writeln('<h1>🤖 flutter-skill explore Report</h1>');
    buffer.writeln(
        '<p style="color:#94a3b8">Generated ${DateTime.now().toIso8601String()} — Start URL: $startUrl</p>');

    buffer.writeln('<div class="summary">');
    buffer.writeln(
        '<div class="stat"><div class="stat-value">${_visited.length}</div><div class="stat-label">Pages Explored</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value errors">$totalBugs</div><div class="stat-label">Bugs Found</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value warnings">$totalA11y</div><div class="stat-label">A11y Issues</div></div>');
    buffer.writeln(
        '<div class="stat"><div class="stat-value">${_consoleErrors.length}</div><div class="stat-label">Console Errors</div></div>');
    buffer.writeln('</div>');

    buffer.writeln('<h2 class="section-title">Pages</h2>');

    for (final entry in _visited.entries) {
      final r = entry.value;
      buffer.writeln('<div class="page">');
      buffer.writeln('<div class="page-url">${_htmlEscape(r.url)}</div>');
      buffer.writeln(
          '<div class="page-meta">Depth: ${r.depth} · Elements: ${r.elementCount} · Links: ${r.discoveredLinks.length}</div>');

      if (r.bugs.isNotEmpty) {
        buffer.writeln('<div class="bugs">');
        for (final bug in r.bugs) {
          buffer.writeln('<div class="bug">🐛 ${_htmlEscape(bug)}</div>');
        }
        buffer.writeln('</div>');
      }

      if (r.accessibilityIssues.isNotEmpty) {
        buffer.writeln('<div class="bugs">');
        for (final issue in r.accessibilityIssues) {
          buffer.writeln(
              '<div class="a11y-issue">♿ ${_htmlEscape(issue)}</div>');
        }
        buffer.writeln('</div>');
      }

      if (r.screenshotBase64 != null) {
        buffer.writeln(
            '<img class="screenshot" src="data:image/jpeg;base64,${r.screenshotBase64}" alt="Screenshot of ${_htmlEscape(r.url)}">');
      }

      buffer.writeln('</div>');
    }

    // Suggestions
    buffer.writeln('<h2 class="section-title">💡 Suggestions</h2>');
    buffer.writeln('<div class="page">');
    if (totalBugs == 0 && totalA11y == 0) {
      buffer.writeln('<p style="color:#4ade80">✅ No issues found! Great job.</p>');
    } else {
      if (totalA11y > 0) {
        buffer.writeln(
            '<p>• Fix accessibility issues: missing alt texts, form labels, and heading hierarchy.</p>');
      }
      if (_consoleErrors.isNotEmpty) {
        buffer.writeln(
            '<p>• Resolve console errors — they may indicate runtime bugs or missing resources.</p>');
      }
      if (totalBugs > 0) {
        buffer.writeln(
            '<p>• Review detected bugs — boundary testing and interaction errors need attention.</p>');
      }
    }
    buffer.writeln('</div>');

    buffer.writeln('</body></html>');

    final file = File(reportPath);
    await file.writeAsString(buffer.toString());
    print('   ✅ Report saved to $reportPath');
  }

  String _htmlEscape(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }
}

class _PageResult {
  final String url;
  final int depth;
  String? screenshotBase64;
  int elementCount = 0;
  List<String> discoveredLinks = [];
  List<String> bugs = [];
  List<String> accessibilityIssues = [];

  _PageResult({required this.url, required this.depth});
}
