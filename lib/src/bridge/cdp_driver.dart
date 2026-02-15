import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../drivers/app_driver.dart';

/// AppDriver that communicates with any web page via Chrome DevTools Protocol.
///
/// No SDK injection needed — connects directly to Chrome's debugging port
/// and controls any web page (React, Vue, Angular, plain HTML, etc.).
class CdpDriver implements AppDriver {
  final String _url;
  final int _port;
  final bool _launchChrome;

  WebSocket? _ws;
  bool _connected = false;
  int _nextId = 1;
  Process? _chromeProcess;

  /// Pending CDP calls keyed by request id.
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  /// Create a CDP driver.
  ///
  /// [url] is the page to navigate to.
  /// [port] is the Chrome remote debugging port.
  /// [launchChrome] whether to launch a new Chrome instance.
  CdpDriver({
    required String url,
    int port = 9222,
    bool launchChrome = true,
  })  : _url = url,
        _port = port,
        _launchChrome = launchChrome;

  @override
  String get frameworkName => 'CDP (Web)';

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    if (_launchChrome) {
      await _launchChromeProcess();
      // Give Chrome a moment to start up
      await Future.delayed(const Duration(seconds: 2));
    }

    // Discover tabs via CDP JSON endpoint
    final wsUrl = await _discoverTarget();
    if (wsUrl == null) {
      throw Exception(
          'Could not find debuggable tab on port $_port. '
          'Ensure Chrome is running with --remote-debugging-port=$_port');
    }

    _ws = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 10));
    _connected = true;

    _ws!.listen(
      _onMessage,
      onDone: _onDisconnect,
      onError: (_) => _onDisconnect(),
      cancelOnError: false,
    );

    // Enable required CDP domains
    await _call('Page.enable');
    await _call('DOM.enable');
    await _call('Runtime.enable');

    // Navigate to URL
    await _call('Page.navigate', {'url': _url});

    // Wait for page to load
    await Future.delayed(const Duration(seconds: 2));
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _failAllPending('Disconnected');
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;

    if (_chromeProcess != null) {
      _chromeProcess!.kill();
      _chromeProcess = null;
    }
  }

  @override
  Future<Map<String, dynamic>> tap({String? key, String? text, String? ref}) async {
    // Find element and get its center coordinates
    final selector = _buildSelector(key: key, text: text, ref: ref);
    final bounds = await _getElementBounds(selector, text: text);
    if (bounds == null) {
      return {
        'success': false,
        'error': {'message': 'Element not found: ${key ?? text ?? ref}'},
      };
    }

    final cx = bounds['cx'] as double;
    final cy = bounds['cy'] as double;

    await _dispatchMouseEvent('mousePressed', cx, cy, button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mouseReleased', cx, cy, button: 'left', clickCount: 1);

    return {
      'success': true,
      'position': {'x': cx, 'y': cy},
    };
  }

  @override
  Future<Map<String, dynamic>> enterText(String? key, String text, {String? ref}) async {
    // Focus the element first
    if (key != null || ref != null) {
      final selector = _buildSelector(key: key, ref: ref);
      final result = await _evalJs('''
        (() => {
          const el = document.querySelector('$selector');
          if (!el) return false;
          el.focus();
          el.value = '';
          return true;
        })()
      ''');
      if (result['result']?['value'] != true) {
        return {
          'success': false,
          'error': {'message': 'Element not found: ${key ?? ref}'},
        };
      }
    }

    // Type each character
    for (final char in text.codeUnits) {
      await _call('Input.dispatchKeyEvent', {
        'type': 'keyDown',
        'text': String.fromCharCode(char),
        'key': String.fromCharCode(char),
        'unmodifiedText': String.fromCharCode(char),
      });
      await _call('Input.dispatchKeyEvent', {
        'type': 'keyUp',
        'key': String.fromCharCode(char),
      });
    }

    // Dispatch input event for frameworks that listen to it
    if (key != null || ref != null) {
      final selector = _buildSelector(key: key, ref: ref);
      await _evalJs('''
        (() => {
          const el = document.querySelector('$selector');
          if (el) {
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
          }
        })()
      ''');
    }

    return {'success': true};
  }

  @override
  Future<bool> swipe({required String direction, double distance = 300, String? key}) async {
    // Get viewport dimensions
    final metrics = await _call('Page.getLayoutMetrics');
    final vw = (metrics['cssLayoutViewport']?['clientWidth'] as num?)?.toDouble() ?? 800.0;
    final vh = (metrics['cssLayoutViewport']?['clientHeight'] as num?)?.toDouble() ?? 600.0;

    double startX = vw / 2, startY = vh / 2, endX = vw / 2, endY = vh / 2;

    switch (direction) {
      case 'up':
        startY = vh / 2 + distance / 2;
        endY = vh / 2 - distance / 2;
        break;
      case 'down':
        startY = vh / 2 - distance / 2;
        endY = vh / 2 + distance / 2;
        break;
      case 'left':
        startX = vw / 2 + distance / 2;
        endX = vw / 2 - distance / 2;
        break;
      case 'right':
        startX = vw / 2 - distance / 2;
        endX = vw / 2 + distance / 2;
        break;
    }

    await _dispatchMouseEvent('mousePressed', startX, startY, button: 'left');
    await _dispatchMouseEvent('mouseMoved', endX, endY, button: 'left');
    await _dispatchMouseEvent('mouseReleased', endX, endY, button: 'left');
    return true;
  }

  @override
  Future<List<dynamic>> getInteractiveElements({bool includePositions = true}) async {
    final result = await _evalJs('''
      (() => {
        const selectors = 'a, button, input, select, textarea, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], [onclick], [tabindex]';
        const elements = Array.from(document.querySelectorAll(selectors));
        return elements.filter(el => {
          const style = window.getComputedStyle(el);
          return style.display !== 'none' && style.visibility !== 'hidden' && el.offsetParent !== null;
        }).map((el, i) => {
          const rect = el.getBoundingClientRect();
          const tag = el.tagName.toLowerCase();
          const type = el.getAttribute('type') || '';
          const role = el.getAttribute('role') || '';
          const text = (el.textContent || '').trim().substring(0, 100);
          const id = el.id || '';
          const name = el.getAttribute('name') || '';
          const ariaLabel = el.getAttribute('aria-label') || '';
          const placeholder = el.getAttribute('placeholder') || '';
          const value = el.value || '';
          return {
            index: i,
            tag: tag,
            type: type || tag,
            role: role,
            text: text,
            key: id || name || null,
            label: ariaLabel || placeholder || '',
            value: value,
            bounds: {
              x: Math.round(rect.left),
              y: Math.round(rect.top),
              w: Math.round(rect.width),
              h: Math.round(rect.height)
            },
            center: {
              x: Math.round(rect.left + rect.width / 2),
              y: Math.round(rect.top + rect.height / 2)
            },
            visible: true,
            clickable: true,
            coordinatesReliable: true
          };
        });
      })()
    ''');

    final value = result['result']?['value'];
    if (value is List) return value;
    // If result is a remote object, need to get properties
    final objectId = result['result']?['objectId'] as String?;
    if (objectId != null) {
      final props = await _call('Runtime.getProperties', {
        'objectId': objectId,
        'ownProperties': true,
      });
      // Parse array-like properties
      final elements = <dynamic>[];
      for (final prop in (props['result'] as List? ?? [])) {
        if (prop is Map && prop['value']?['type'] == 'object' && prop['name'] != '__proto__' && prop['name'] != 'length') {
          final elObjId = prop['value']['objectId'] as String?;
          if (elObjId != null) {
            final elProps = await _call('Runtime.getProperties', {
              'objectId': elObjId,
              'ownProperties': true,
            });
            final map = <String, dynamic>{};
            for (final p in (elProps['result'] as List? ?? [])) {
              if (p is Map && p['name'] != '__proto__') {
                final v = p['value'];
                if (v?['type'] == 'object' && v?['objectId'] != null) {
                  // nested object (bounds, center) — get properties
                  final nested = await _call('Runtime.getProperties', {
                    'objectId': v['objectId'],
                    'ownProperties': true,
                  });
                  final nestedMap = <String, dynamic>{};
                  for (final np in (nested['result'] as List? ?? [])) {
                    if (np is Map && np['name'] != '__proto__') {
                      nestedMap[np['name']] = np['value']?['value'];
                    }
                  }
                  map[p['name']] = nestedMap;
                } else {
                  map[p['name']] = v?['value'];
                }
              }
            }
            elements.add(map);
          }
        }
      }
      return elements;
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> getInteractiveElementsStructured() async {
    final result = await _evalJs('''
      (() => {
        const selectors = 'a, button, input, select, textarea, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], [onclick], [tabindex]';
        const elements = Array.from(document.querySelectorAll(selectors));
        const visible = elements.filter(el => {
          const style = window.getComputedStyle(el);
          return style.display !== 'none' && style.visibility !== 'hidden' && el.offsetParent !== null;
        });
        const mapped = visible.map((el, i) => {
          const rect = el.getBoundingClientRect();
          const tag = el.tagName.toLowerCase();
          const type = el.getAttribute('type') || '';
          const role = el.getAttribute('role') || tag;
          const text = (el.textContent || '').trim().substring(0, 100);
          const id = el.id || '';
          const name = el.getAttribute('name') || '';
          const ariaLabel = el.getAttribute('aria-label') || '';
          const placeholder = el.getAttribute('placeholder') || '';
          
          let refName = '';
          if (tag === 'button' || role === 'button') refName = 'button:' + (text || ariaLabel || id || ('idx_' + i));
          else if (tag === 'input' || tag === 'textarea') refName = 'input:' + (ariaLabel || placeholder || name || id || ('idx_' + i));
          else if (tag === 'a' || role === 'link') refName = 'link:' + (text || ariaLabel || id || ('idx_' + i));
          else if (tag === 'select') refName = 'select:' + (ariaLabel || name || id || ('idx_' + i));
          else refName = role + ':' + (text || ariaLabel || id || ('idx_' + i));
          
          const actions = [];
          actions.push('tap');
          if (tag === 'input' || tag === 'textarea') actions.push('enter_text');
          if (tag === 'select') actions.push('select');
          
          return {
            type: tag,
            text: text,
            label: ariaLabel || placeholder,
            ref: refName,
            selector: id ? ('#' + id) : (name ? ('[name="' + name + '"]') : null),
            actions: actions,
            bounds: { x: Math.round(rect.left), y: Math.round(rect.top), w: Math.round(rect.width), h: Math.round(rect.height) },
            enabled: !el.disabled,
            visible: true,
            value: el.value || null
          };
        });
        
        const summary = 'Found ' + mapped.length + ' interactive elements';
        return JSON.stringify({elements: mapped, summary: summary});
      })()
    ''');

    final value = result['result']?['value'];
    if (value is String) {
      return (jsonDecode(value) as Map<String, dynamic>);
    }
    return {'elements': [], 'summary': 'Failed to inspect elements'};
  }

  @override
  Future<String?> takeScreenshot({double quality = 1.0, int? maxWidth}) async {
    final params = <String, dynamic>{
      'format': 'png',
    };
    if (quality < 1.0) {
      params['format'] = 'jpeg';
      params['quality'] = (quality * 100).round();
    }
    final result = await _call('Page.captureScreenshot', params);
    return result['data'] as String?;
  }

  @override
  Future<List<String>> getLogs() async {
    // CDP doesn't have a built-in log store; return console messages if captured
    return [];
  }

  @override
  Future<void> clearLogs() async {
    // No-op for CDP
  }

  @override
  Future<void> hotReload() async {
    await _call('Page.reload');
  }

  // ── Extended methods used by server.dart ──

  /// Take a screenshot of a specific region.
  Future<String?> takeRegionScreenshot(double x, double y, double width, double height) async {
    final result = await _call('Page.captureScreenshot', {
      'format': 'png',
      'clip': {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'scale': 1,
      },
    });
    return result['data'] as String?;
  }

  /// Take a screenshot of a specific element.
  Future<String?> takeElementScreenshot(String selector) async {
    final bounds = await _getElementBounds(selector);
    if (bounds == null) return null;
    return takeRegionScreenshot(
      bounds['x'] as double,
      bounds['y'] as double,
      bounds['w'] as double,
      bounds['h'] as double,
    );
  }

  /// Scroll an element into view.
  Future<Map<String, dynamic>> scrollTo({String? key, String? text}) async {
    final selector = _buildSelector(key: key, text: text);
    final result = await _evalJs('''
      (() => {
        const el = ${_jsFindElement(selector, text: text)};
        if (!el) return false;
        el.scrollIntoView({behavior: 'smooth', block: 'center'});
        return true;
      })()
    ''');
    final found = result['result']?['value'] == true;
    return {'success': found, 'message': found ? 'Scrolled to element' : 'Element not found'};
  }

  /// Navigate back.
  Future<bool> goBack() async {
    await _evalJs("history.back()");
    await Future.delayed(const Duration(milliseconds: 300));
    return true;
  }

  /// Get current URL.
  Future<String> getCurrentRoute() async {
    final result = await _evalJs('window.location.href');
    return (result['result']?['value'] as String?) ?? '';
  }

  /// Evaluate JavaScript.
  Future<Map<String, dynamic>> evaluate(String expression) async {
    return _evalJs(expression);
  }

  /// Wait for an element to appear.
  Future<bool> waitForElement({String? key, String? text, int timeout = 5000}) async {
    final selector = _buildSelector(key: key, text: text);
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < timeout) {
      final result = await _evalJs('''
        (() => {
          const el = ${_jsFindElement(selector, text: text)};
          return el !== null && el !== undefined;
        })()
      ''');
      if (result['result']?['value'] == true) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  /// Wait for an element to disappear.
  Future<bool> waitForGone({String? key, String? text, int timeout = 5000}) async {
    final selector = _buildSelector(key: key, text: text);
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < timeout) {
      final result = await _evalJs('''
        (() => {
          const el = ${_jsFindElement(selector, text: text)};
          return el === null || el === undefined;
        })()
      ''');
      if (result['result']?['value'] == true) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  /// Assert visibility of an element.
  Future<bool> assertVisible({String? key, String? text}) async {
    final selector = _buildSelector(key: key, text: text);
    final result = await _evalJs('''
      (() => {
        const el = ${_jsFindElement(selector, text: text)};
        if (!el) return false;
        const style = window.getComputedStyle(el);
        return style.display !== 'none' && style.visibility !== 'hidden' && el.offsetParent !== null;
      })()
    ''');
    return result['result']?['value'] == true;
  }

  /// Tap at specific coordinates.
  Future<void> tapAt(double x, double y) async {
    await _dispatchMouseEvent('mousePressed', x, y, button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mouseReleased', x, y, button: 'left', clickCount: 1);
  }

  /// Long press an element.
  Future<bool> longPress({String? key, String? text, int duration = 500}) async {
    final selector = _buildSelector(key: key, text: text);
    final bounds = await _getElementBounds(selector, text: text);
    if (bounds == null) return false;
    final cx = bounds['cx'] as double;
    final cy = bounds['cy'] as double;
    await _dispatchMouseEvent('mousePressed', cx, cy, button: 'left');
    await Future.delayed(Duration(milliseconds: duration));
    await _dispatchMouseEvent('mouseReleased', cx, cy, button: 'left');
    return true;
  }

  /// Double-tap an element.
  Future<bool> doubleTap({String? key, String? text}) async {
    final selector = _buildSelector(key: key, text: text);
    final bounds = await _getElementBounds(selector, text: text);
    if (bounds == null) return false;
    final cx = bounds['cx'] as double;
    final cy = bounds['cy'] as double;
    await _dispatchMouseEvent('mousePressed', cx, cy, button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mouseReleased', cx, cy, button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mousePressed', cx, cy, button: 'left', clickCount: 2);
    await _dispatchMouseEvent('mouseReleased', cx, cy, button: 'left', clickCount: 2);
    return true;
  }

  /// Get text value of an input element.
  Future<String?> getTextValue(String key) async {
    final result = await _evalJs('''
      (() => {
        const el = document.querySelector('#$key') || document.querySelector('[name="$key"]');
        return el ? (el.value || el.textContent || '') : null;
      })()
    ''');
    return result['result']?['value'] as String?;
  }

  /// Get all text content on the page.
  Future<String> getTextContent() async {
    final result = await _evalJs('document.body.innerText');
    return (result['result']?['value'] as String?) ?? '';
  }

  /// Get navigation stack (just current URL for web).
  Future<List<String>> getNavigationStack() async {
    final url = await getCurrentRoute();
    return [url];
  }

  // ── Internal helpers ──

  Future<void> _launchChromeProcess() async {
    final chromePaths = <String>[];

    if (Platform.isMacOS) {
      chromePaths.add('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
      chromePaths.add('/Applications/Chromium.app/Contents/MacOS/Chromium');
    } else if (Platform.isLinux) {
      chromePaths.addAll(['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser']);
    } else if (Platform.isWindows) {
      chromePaths.add(r'C:\Program Files\Google\Chrome\Application\chrome.exe');
      chromePaths.add(r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe');
    }

    // Create a temporary user data dir so we don't conflict with existing Chrome
    final tmpDir = await Directory.systemTemp.createTemp('cdp_chrome_');

    for (final chromePath in chromePaths) {
      try {
        _chromeProcess = await Process.start(chromePath, [
          '--remote-debugging-port=$_port',
          '--no-first-run',
          '--no-default-browser-check',
          '--user-data-dir=${tmpDir.path}',
          '--disable-background-timer-throttling',
          '--disable-backgrounding-occluded-windows',
          '--disable-renderer-backgrounding',
          _url,
        ]);
        return;
      } catch (_) {
        continue;
      }
    }

    throw Exception(
        'Could not find Chrome. Tried: ${chromePaths.join(', ')}. '
        'Start Chrome manually with --remote-debugging-port=$_port');
  }

  Future<String?> _discoverTarget() async {
    // Try multiple times as Chrome may still be starting
    for (var i = 0; i < 10; i++) {
      try {
        final client = HttpClient();
        final request = await client.getUrl(Uri.parse('http://127.0.0.1:$_port/json'));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        client.close();

        final tabs = jsonDecode(body) as List;
        // Prefer tab already showing the target URL
        for (final tab in tabs) {
          if (tab is Map && tab['type'] == 'page' && tab['url'] == _url) {
            return tab['webSocketDebuggerUrl'] as String?;
          }
        }
        // Fall back to first page tab
        for (final tab in tabs) {
          if (tab is Map && tab['type'] == 'page') {
            return tab['webSocketDebuggerUrl'] as String?;
          }
        }
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _call(String method, [Map<String, dynamic>? params]) async {
    if (_ws == null || !_connected) {
      throw Exception('Not connected via CDP');
    }

    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    final request = jsonEncode({
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    });
    _ws!.add(request);

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('CDP call "$method" timed out', const Duration(seconds: 30));
      },
    );
  }

  Future<Map<String, dynamic>> _evalJs(String expression) async {
    return _call('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': false,
    });
  }

  Future<void> _dispatchMouseEvent(
    String type,
    double x,
    double y, {
    String button = 'none',
    int clickCount = 0,
  }) async {
    await _call('Input.dispatchMouseEvent', {
      'type': type,
      'x': x,
      'y': y,
      'button': button,
      'clickCount': clickCount,
    });
  }

  /// Build a CSS selector from key/ref parameters.
  String _buildSelector({String? key, String? text, String? ref}) {
    if (key != null) {
      return '#$key, [name="$key"], [data-testid="$key"], [data-key="$key"]';
    }
    if (ref != null) {
      // Refs like "button:Login" — actual search is done in _jsFindElement via JS
      return '[data-ref="$ref"]';
    }
    if (text != null) {
      return '[data-text="$text"]'; // placeholder, actual search done in JS
    }
    return '*';
  }

  /// Generate JS code to find an element by selector or text.
  String _jsFindElement(String selector, {String? text, String? ref}) {
    if (text != null) {
      final escaped = text.replaceAll("'", "\\'").replaceAll('\n', '\\n');
      return '''(() => {
        // Try CSS selector first
        let el = document.querySelector('$selector');
        if (el) return el;
        // Search by text content
        const all = document.querySelectorAll('a, button, input, select, textarea, label, span, p, h1, h2, h3, h4, h5, h6, div, li, td, th, [role]');
        for (const e of all) {
          if (e.textContent && e.textContent.trim() === '$escaped') return e;
        }
        // Partial match
        for (const e of all) {
          if (e.textContent && e.textContent.trim().includes('$escaped')) return e;
        }
        return null;
      })()''';
    }
    if (ref != null) {
      final parts = ref.split(':');
      if (parts.length >= 2) {
        final tag = parts[0];
        final refText = parts.sublist(1).join(':').replaceAll("'", "\\'");
        String tagSelector;
        switch (tag) {
          case 'button':
            tagSelector = 'button, [role="button"], input[type="submit"], input[type="button"]';
            break;
          case 'input':
            tagSelector = 'input, textarea, select';
            break;
          case 'link':
            tagSelector = 'a, [role="link"]';
            break;
          default:
            tagSelector = '*';
        }
        return '''(() => {
          const candidates = document.querySelectorAll('$tagSelector');
          for (const e of candidates) {
            const t = (e.textContent || '').trim();
            const label = e.getAttribute('aria-label') || e.getAttribute('placeholder') || '';
            if (t === '$refText' || label === '$refText' || e.id === '$refText') return e;
          }
          for (const e of candidates) {
            const t = (e.textContent || '').trim();
            if (t.includes('$refText')) return e;
          }
          return null;
        })()''';
      }
    }
    return "document.querySelector('$selector')";
  }

  /// Get element bounds (returns {x, y, w, h, cx, cy} or null).
  Future<Map<String, double>?> _getElementBounds(String selector, {String? text, String? ref}) async {
    final result = await _evalJs('''
      (() => {
        const el = ${_jsFindElement(selector, text: text, ref: ref)};
        if (!el) return null;
        const rect = el.getBoundingClientRect();
        return {
          x: rect.left,
          y: rect.top,
          w: rect.width,
          h: rect.height,
          cx: rect.left + rect.width / 2,
          cy: rect.top + rect.height / 2
        };
      })()
    ''');

    final value = result['result']?['value'];
    if (value is Map) {
      return {
        'x': (value['x'] as num).toDouble(),
        'y': (value['y'] as num).toDouble(),
        'w': (value['w'] as num).toDouble(),
        'h': (value['h'] as num).toDouble(),
        'cx': (value['cx'] as num).toDouble(),
        'cy': (value['cy'] as num).toDouble(),
      };
    }
    return null;
  }

  void _onMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final id = json['id'] as int?;
      if (id != null && _pending.containsKey(id)) {
        final completer = _pending.remove(id)!;
        if (json.containsKey('error')) {
          final err = json['error'] as Map<String, dynamic>;
          completer.completeError(Exception(
            'CDP error ${err['code']}: ${err['message']}',
          ));
        } else {
          completer.complete((json['result'] as Map<String, dynamic>?) ?? {});
        }
      }
      // CDP events (no id) are ignored for now
    } catch (e) {
      // Malformed message
    }
  }

  void _onDisconnect() {
    _connected = false;
    _failAllPending('Connection lost');
  }

  void _failAllPending(String reason) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('CDP: $reason'));
      }
    }
    _pending.clear();
  }
}
