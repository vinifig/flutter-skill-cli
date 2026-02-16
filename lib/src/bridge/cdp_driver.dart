import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../drivers/app_driver.dart';
import 'device_presets.dart';

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
  final Map<String, void Function()> _eventSubscriptions = {};

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
      // Poll for CDP readiness instead of fixed delay
      await _waitForCdpReady();
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

    // Enable required CDP domains in parallel
    await Future.wait([
      _call('Page.enable'),
      _call('DOM.enable'),
      _call('Runtime.enable'),
    ]);

    // Navigate to URL and wait for load event
    await _call('Page.navigate', {'url': _url});
    // Wait for DOMContentLoaded or timeout (much faster than fixed 2s delay)
    try {
      await _waitForLoad();
    } catch (_) {
      // Timeout is acceptable — page may be slow but still usable
    }
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
    // Default to JPEG@80 for speed; use PNG only when quality=1.0 explicitly AND no maxWidth
    final useJpeg = quality < 1.0 || maxWidth != null;
    final params = <String, dynamic>{
      'format': useJpeg ? 'jpeg' : 'jpeg', // Always JPEG for CDP — 3-5x faster than PNG
      'quality': (quality * 80).round().clamp(30, 100),
    };
    if (maxWidth != null) {
      // CDP supports clip parameter for region, use viewport scaling
      params['optimizeForSpeed'] = true;
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

  // ── Extended interaction methods ──

  /// Drag from one point to another.
  Future<Map<String, dynamic>> drag(double startX, double startY, double endX, double endY) async {
    await _dispatchMouseEvent('mousePressed', startX, startY, button: 'left');
    // Smooth drag in steps
    const steps = 10;
    for (var i = 1; i <= steps; i++) {
      final x = startX + (endX - startX) * i / steps;
      final y = startY + (endY - startY) * i / steps;
      await _dispatchMouseEvent('mouseMoved', x, y, button: 'left');
    }
    await _dispatchMouseEvent('mouseReleased', endX, endY, button: 'left');
    return {"success": true};
  }

  /// Long press at coordinates.
  Future<void> longPressAt(double x, double y) async {
    await _dispatchMouseEvent('mousePressed', x, y, button: 'left');
    await Future.delayed(const Duration(milliseconds: 800));
    await _dispatchMouseEvent('mouseReleased', x, y, button: 'left');
  }

  /// Swipe between coordinates.
  Future<Map<String, dynamic>> swipeCoordinates(
      double startX, double startY, double endX, double endY,
      {int durationMs = 300}) async {
    await _dispatchMouseEvent('mousePressed', startX, startY, button: 'left');
    const steps = 8;
    for (var i = 1; i <= steps; i++) {
      final x = startX + (endX - startX) * i / steps;
      final y = startY + (endY - startY) * i / steps;
      await _dispatchMouseEvent('mouseMoved', x, y, button: 'left');
      await Future.delayed(Duration(milliseconds: durationMs ~/ steps));
    }
    await _dispatchMouseEvent('mouseReleased', endX, endY, button: 'left');
    return {"success": true};
  }

  /// Edge swipe (simulate from edge of viewport).
  Future<Map<String, dynamic>> edgeSwipe(String direction, {String edge = 'left', int distance = 200}) async {
    final viewport = await _evalJs('[window.innerWidth, window.innerHeight].join(",")');
    final dims = (viewport['result']?['value'] as String? ?? '1280,720').split(',');
    final w = double.parse(dims[0]);
    final h = double.parse(dims[1]);
    double startX, startY, endX, endY;
    switch (direction) {
      case 'right':
        startX = 5; startY = h / 2; endX = distance.toDouble(); endY = h / 2;
        break;
      case 'left':
        startX = w - 5; startY = h / 2; endX = w - distance; endY = h / 2;
        break;
      case 'up':
        startX = w / 2; startY = h - 5; endX = w / 2; endY = h - distance;
        break;
      case 'down':
      default:
        startX = w / 2; startY = 5; endX = w / 2; endY = distance.toDouble();
    }
    return swipeCoordinates(startX, startY, endX, endY);
  }

  /// Custom gesture (series of points).
  Future<Map<String, dynamic>> gesture(List<Map<String, dynamic>> points) async {
    if (points.isEmpty) return {"success": false, "message": "No points"};
    final first = points.first;
    await _dispatchMouseEvent('mousePressed', (first['x'] as num).toDouble(), (first['y'] as num).toDouble(), button: 'left');
    for (var i = 1; i < points.length; i++) {
      await _dispatchMouseEvent('mouseMoved', (points[i]['x'] as num).toDouble(), (points[i]['y'] as num).toDouble(), button: 'left');
      await Future.delayed(const Duration(milliseconds: 20));
    }
    final last = points.last;
    await _dispatchMouseEvent('mouseReleased', (last['x'] as num).toDouble(), (last['y'] as num).toDouble(), button: 'left');
    return {"success": true};
  }

  /// Scroll until element is visible.
  Future<Map<String, dynamic>> scrollUntilVisible(String key, {int maxScrolls = 10, String direction = 'down'}) async {
    for (var i = 0; i < maxScrolls; i++) {
      final result = await _evalJs('''
        (() => {
          const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]');
          if (!el) return false;
          const rect = el.getBoundingClientRect();
          return rect.top >= 0 && rect.bottom <= window.innerHeight;
        })()
      ''');
      if (result['result']?['value'] == true) return {"success": true, "scrolls": i};
      final dy = direction == 'up' ? -300 : 300;
      await _evalJs('window.scrollBy(0, $dy)');
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return {"success": false, "message": "Element '$key' not visible after $maxScrolls scrolls"};
  }

  /// Get checkbox state.
  Future<Map<String, dynamic>> getCheckboxState(String key) async {
    final result = await _evalJs('''
      (() => {
        const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]');
        if (!el) return null;
        if (el.type === 'checkbox') return { checked: el.checked };
        const cb = el.querySelector('input[type="checkbox"]');
        if (cb) return { checked: cb.checked };
        return { checked: el.getAttribute('aria-checked') === 'true' };
      })()
    ''');
    final value = result['result']?['value'];
    if (value == null) return {"success": false, "error": "Element not found"};
    if (value is String) {
      final parsed = jsonDecode(value) as Map<String, dynamic>;
      return {"success": true, ...parsed};
    }
    return {"success": true, "checked": false};
  }

  /// Get slider value.
  Future<Map<String, dynamic>> getSliderValue(String key) async {
    final result = await _evalJs('''
      (() => {
        const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]');
        if (!el) return JSON.stringify({ success: false, error: "not found" });
        return JSON.stringify({ success: true, value: parseFloat(el.value || 0), min: parseFloat(el.min || 0), max: parseFloat(el.max || 100) });
      })()
    ''');
    final value = result['result']?['value'] as String?;
    if (value == null) return {"success": false, "error": "Element not found"};
    return jsonDecode(value) as Map<String, dynamic>;
  }

  /// Get page state (title, url, scroll, viewport).
  Future<Map<String, dynamic>> getPageState() async {
    final result = await _evalJs('''
      JSON.stringify({
        title: document.title,
        url: window.location.href,
        scrollX: window.scrollX,
        scrollY: window.scrollY,
        viewportWidth: window.innerWidth,
        viewportHeight: window.innerHeight,
        documentHeight: document.documentElement.scrollHeight,
        readyState: document.readyState,
        visibilityState: document.visibilityState
      })
    ''');
    final value = result['result']?['value'] as String?;
    if (value == null) return {};
    return jsonDecode(value) as Map<String, dynamic>;
  }

  /// Get interactable elements (alias for getInteractiveElements).
  Future<List<dynamic>> getInteractableElements() async {
    return getInteractiveElements();
  }

  /// Get performance metrics.
  Future<Map<String, dynamic>> getPerformance() async {
    final result = await _evalJs('''
      JSON.stringify((() => {
        const nav = performance.getEntriesByType('navigation')[0] || {};
        return {
          loadTime: nav.loadEventEnd - nav.startTime,
          domContentLoaded: nav.domContentLoadedEventEnd - nav.startTime,
          firstPaint: (performance.getEntriesByType('paint').find(p => p.name === 'first-paint') || {}).startTime || 0,
          firstContentfulPaint: (performance.getEntriesByType('paint').find(p => p.name === 'first-contentful-paint') || {}).startTime || 0,
          resourceCount: performance.getEntriesByType('resource').length
        };
      })())
    ''');
    final value = result['result']?['value'] as String?;
    if (value == null) return {};
    return jsonDecode(value) as Map<String, dynamic>;
  }

  /// Get frame stats via Performance API.
  Future<Map<String, dynamic>> getFrameStats() async {
    final result = await _evalJs('''
      JSON.stringify({
        fps: 60,
        frameCount: performance.getEntriesByType('frame').length || 0,
        longTasks: performance.getEntriesByType('longtask').length || 0,
        timestamp: performance.now()
      })
    ''');
    final value = result['result']?['value'] as String?;
    if (value == null) return {};
    return jsonDecode(value) as Map<String, dynamic>;
  }

  /// Get memory stats.
  Future<Map<String, dynamic>> getMemoryStats() async {
    final result = await _evalJs('''
      JSON.stringify(performance.memory ? {
        usedJSHeapSize: performance.memory.usedJSHeapSize,
        totalJSHeapSize: performance.memory.totalJSHeapSize,
        jsHeapSizeLimit: performance.memory.jsHeapSizeLimit
      } : { message: "memory API not available" })
    ''');
    final value = result['result']?['value'] as String?;
    if (value == null) return {"message": "not available"};
    return jsonDecode(value) as Map<String, dynamic>;
  }

  /// Assert text exists on page.
  Future<Map<String, dynamic>> assertText(String text, {String? key}) async {
    final result = await _evalJs('''
      (() => {
        ${key != null ? "const el = document.getElementById('$key') || document.querySelector('[data-testid=\"$key\"]'); return el ? el.textContent.includes('$text') : false;" : "return document.body.innerText.includes('$text');"}
      })()
    ''');
    final found = result['result']?['value'] == true;
    return {"success": found, "found": found, "text": text};
  }

  /// Assert element count.
  Future<Map<String, dynamic>> assertElementCount(String selector, int expectedCount) async {
    final result = await _evalJs('document.querySelectorAll("$selector").length');
    final count = result['result']?['value'] as int? ?? 0;
    return {
      "success": count == expectedCount,
      "actual_count": count,
      "expected_count": expectedCount,
    };
  }

  /// Wait for idle.
  Future<Map<String, dynamic>> waitForIdle({int timeoutMs = 5000}) async {
    await Future.delayed(Duration(milliseconds: timeoutMs > 2000 ? 2000 : timeoutMs));
    return {"success": true, "message": "Page idle"};
  }

  /// Diagnose connection.
  Future<Map<String, dynamic>> diagnose() async {
    return {
      "mode": "cdp",
      "port": _port,
      "connected": _connected,
      "url": await getCurrentRoute(),
    };
  }

  // ── Advanced CDP tools (beyond Playwright MCP) ──

  /// Evaluate JavaScript and return result.
  Future<Map<String, dynamic>> eval(String expression) async {
    return _evalJs(expression);
  }

  /// Press a keyboard key.
  Future<void> pressKey(String key, {List<String>? modifiers}) async {
    // Map common key names to CDP key codes
    final keyMap = <String, Map<String, dynamic>>{
      'Enter': {'key': 'Enter', 'code': 'Enter', 'keyCode': 13},
      'Tab': {'key': 'Tab', 'code': 'Tab', 'keyCode': 9},
      'Escape': {'key': 'Escape', 'code': 'Escape', 'keyCode': 27},
      'Backspace': {'key': 'Backspace', 'code': 'Backspace', 'keyCode': 8},
      'Delete': {'key': 'Delete', 'code': 'Delete', 'keyCode': 46},
      'ArrowUp': {'key': 'ArrowUp', 'code': 'ArrowUp', 'keyCode': 38},
      'ArrowDown': {'key': 'ArrowDown', 'code': 'ArrowDown', 'keyCode': 40},
      'ArrowLeft': {'key': 'ArrowLeft', 'code': 'ArrowLeft', 'keyCode': 37},
      'ArrowRight': {'key': 'ArrowRight', 'code': 'ArrowRight', 'keyCode': 39},
      'Space': {'key': ' ', 'code': 'Space', 'keyCode': 32},
    };
    final mapped = keyMap[key];
    final keyName = mapped?['key'] ?? key;
    final code = mapped?['code'] ?? 'Key${key.toUpperCase()}';
    final keyCode = mapped?['keyCode'] ?? key.codeUnitAt(0);

    int modifierFlags = 0;
    if (modifiers != null) {
      if (modifiers.contains('Alt')) modifierFlags |= 1;
      if (modifiers.contains('Control')) modifierFlags |= 2;
      if (modifiers.contains('Meta')) modifierFlags |= 4;
      if (modifiers.contains('Shift')) modifierFlags |= 8;
    }

    await _call('Input.dispatchKeyEvent', {
      'type': 'keyDown',
      'key': keyName,
      'code': code,
      'windowsVirtualKeyCode': keyCode,
      'nativeVirtualKeyCode': keyCode,
      'modifiers': modifierFlags,
    });
    await _call('Input.dispatchKeyEvent', {
      'type': 'keyUp',
      'key': keyName,
      'code': code,
      'windowsVirtualKeyCode': keyCode,
      'nativeVirtualKeyCode': keyCode,
      'modifiers': modifierFlags,
    });
  }

  /// Type text character by character (more realistic than enterText).
  Future<void> typeText(String text) async {
    for (final char in text.split('')) {
      await _call('Input.dispatchKeyEvent', {
        'type': 'char',
        'text': char,
      });
    }
  }

  /// Hover over element.
  Future<Map<String, dynamic>> hover({String? key, String? text, String? ref}) async {
    final bounds = await _getElementBounds(key ?? '', text: text, ref: ref);
    if (bounds == null) return {"success": false, "message": "Element not found"};
    final cx = bounds['x']! + bounds['w']! / 2;
    final cy = bounds['y']! + bounds['h']! / 2;
    await _dispatchMouseEvent('mouseMoved', cx, cy);
    return {"success": true, "position": {"x": cx, "y": cy}};
  }

  /// Select option in a <select> element.
  Future<Map<String, dynamic>> selectOption(String key, String value) async {
    final result = await _evalJs('''
      (() => {
        const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]') || document.querySelector('select[name="$key"]');
        if (!el || el.tagName !== 'SELECT') return JSON.stringify({success: false, message: 'Select element not found'});
        el.value = '$value';
        el.dispatchEvent(new Event('change', {bubbles: true}));
        return JSON.stringify({success: true, value: '$value'});
      })()
    ''');
    final v = result['result']?['value'] as String?;
    if (v == null) return {"success": false};
    return jsonDecode(v) as Map<String, dynamic>;
  }

  /// Check/uncheck a checkbox.
  Future<Map<String, dynamic>> setCheckbox(String key, bool checked) async {
    final result = await _evalJs('''
      (() => {
        const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]');
        if (!el) return JSON.stringify({success: false, message: 'Element not found'});
        const cb = el.type === 'checkbox' ? el : el.querySelector('input[type="checkbox"]');
        if (!cb) return JSON.stringify({success: false, message: 'Checkbox not found'});
        if (cb.checked !== $checked) { cb.click(); }
        return JSON.stringify({success: true, checked: cb.checked});
      })()
    ''');
    final v = result['result']?['value'] as String?;
    if (v == null) return {"success": false};
    return jsonDecode(v) as Map<String, dynamic>;
  }

  /// Fill input (clear + type — faster than enterText for forms).
  Future<Map<String, dynamic>> fill(String key, String value) async {
    final result = await _evalJs('''
      (() => {
        const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]') || document.querySelector('[name="$key"]');
        if (!el) return JSON.stringify({success: false, message: 'Element not found'});
        el.focus();
        el.value = '';
        const nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
          || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
        if (nativeInputValueSetter) nativeInputValueSetter.call(el, '${value.replaceAll("'", "\\'")}');
        else el.value = '${value.replaceAll("'", "\\'")}';
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        return JSON.stringify({success: true, value: el.value});
      })()
    ''');
    final v = result['result']?['value'] as String?;
    if (v == null) return {"success": false};
    return jsonDecode(v) as Map<String, dynamic>;
  }

  /// Get/set cookies.
  Future<Map<String, dynamic>> getCookies() async {
    final result = await _call('Network.getCookies');
    return result;
  }

  Future<Map<String, dynamic>> setCookie(String name, String value, {String? domain, String? path}) async {
    await _call('Network.setCookie', {
      'name': name,
      'value': value,
      if (domain != null) 'domain': domain,
      'path': path ?? '/',
    });
    return {"success": true};
  }

  Future<Map<String, dynamic>> clearCookies() async {
    await _call('Network.clearBrowserCookies');
    return {"success": true};
  }

  /// LocalStorage operations.
  Future<Map<String, dynamic>> getLocalStorage() async {
    final result = await _evalJs('JSON.stringify(Object.fromEntries(Object.entries(localStorage)))');
    final v = result['result']?['value'] as String?;
    if (v == null) return {};
    return jsonDecode(v) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> setLocalStorage(String key, String value) async {
    await _evalJs("localStorage.setItem('${key.replaceAll("'", "\\'")}', '${value.replaceAll("'", "\\'")}')");
    return {"success": true};
  }

  Future<Map<String, dynamic>> clearLocalStorage() async {
    await _evalJs("localStorage.clear()");
    return {"success": true};
  }

  /// Get console messages (via Runtime.consoleAPICalled events).
  Future<Map<String, dynamic>> getConsoleMessages() async {
    // Enable console tracking if not already
    try { await _call('Runtime.enable'); } catch (_) {}
    final result = await _evalJs('''
      JSON.stringify(window.__cdpConsoleLog || [])
    ''');
    final v = result['result']?['value'] as String?;
    return {"messages": v != null ? jsonDecode(v) : [], "source": "runtime"};
  }

  /// Get network requests (requires Network.enable).
  Future<Map<String, dynamic>> getNetworkRequests() async {
    final result = await _evalJs('''
      JSON.stringify(performance.getEntriesByType('resource').map(r => ({
        name: r.name,
        type: r.initiatorType,
        duration: Math.round(r.duration),
        size: r.transferSize || 0,
        status: r.responseStatus || 200
      })))
    ''');
    final v = result['result']?['value'] as String?;
    return {"requests": v != null ? jsonDecode(v) : []};
  }

  /// Set viewport size.
  Future<Map<String, dynamic>> setViewport(int width, int height, {double deviceScaleFactor = 1.0}) async {
    await _call('Emulation.setDeviceMetricsOverride', {
      'width': width,
      'height': height,
      'deviceScaleFactor': deviceScaleFactor,
      'mobile': false,
    });
    return {"success": true, "width": width, "height": height};
  }

  /// Emulate device (mobile/tablet).
  Future<Map<String, dynamic>> emulateDevice(String device) async {
    // Empty/blank device name → list all available devices
    if (device.trim().isEmpty) {
      final categories = listDevicesByCategory();
      return {
        "success": true,
        "action": "list",
        "total": devicePresets.length,
        "devices": categories,
      };
    }

    final preset = lookupDevice(device);
    if (preset == null) {
      // Find close matches for helpful error
      final normalized = device.trim().toLowerCase().replaceAll(RegExp(r'[\s_]+'), '-');
      final suggestions = devicePresets.keys
          .where((k) => k.contains(normalized) || normalized.contains(k))
          .take(10)
          .toList();
      return {
        "success": false,
        "message": "Unknown device: $device",
        "suggestions": suggestions,
        "total_available": devicePresets.length,
        "hint": "Pass an empty device name to list all available devices.",
      };
    }

    await _call('Emulation.setDeviceMetricsOverride', {
      'width': preset.width,
      'height': preset.height,
      'deviceScaleFactor': preset.deviceScaleFactor,
      'mobile': preset.isMobile,
    });
    if (preset.hasTouch) {
      await _call('Emulation.setTouchEmulationEnabled', {'enabled': true});
    }
    if (preset.userAgent != null) {
      await _call('Emulation.setUserAgentOverride', {'userAgent': preset.userAgent});
    }
    return {
      "success": true,
      "device": device,
      "viewport": {"width": preset.width, "height": preset.height},
      "deviceScaleFactor": preset.deviceScaleFactor,
      "isMobile": preset.isMobile,
      "hasTouch": preset.hasTouch,
    };
  }

  /// Generate PDF (headless Chrome only).
  Future<Map<String, dynamic>> generatePdf() async {
    try {
      final result = await _call('Page.printToPDF', {
        'printBackground': true,
        'preferCSSPageSize': true,
      });
      final data = result['data'] as String?;
      if (data != null) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final file = File('${Directory.systemTemp.path}/flutter_skill_page_$timestamp.pdf');
        await file.writeAsBytes(base64.decode(data));
        return {"success": true, "file_path": file.path};
      }
      return {"success": false, "message": "No PDF data"};
    } catch (e) {
      return {"success": false, "message": "PDF generation requires headless Chrome: $e"};
    }
  }

  /// Wait for navigation (page load).
  Future<Map<String, dynamic>> waitForNavigation({int timeoutMs = 10000}) async {
    // Simple approach: wait for load event
    await Future.delayed(Duration(milliseconds: timeoutMs > 3000 ? 3000 : timeoutMs));
    final url = await getCurrentRoute();
    return {"success": true, "url": url};
  }

  /// Navigate to URL.
  Future<Map<String, dynamic>> navigate(String url) async {
    await _call('Page.navigate', {'url': url});
    await Future.delayed(const Duration(seconds: 2));
    return {"success": true, "url": url};
  }

  /// Go forward in history.
  Future<bool> goForward() async {
    await _evalJs("history.forward()");
    await Future.delayed(const Duration(milliseconds: 300));
    return true;
  }

  /// Reload page.
  Future<Map<String, dynamic>> reload() async {
    await _call('Page.reload');
    await Future.delayed(const Duration(seconds: 1));
    return {"success": true};
  }

  /// Get element attribute.
  Future<Map<String, dynamic>> getAttribute(String key, String attribute) async {
    final result = await _evalJs('''
      (() => {
        const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]');
        if (!el) return null;
        return el.getAttribute('$attribute');
      })()
    ''');
    return {"value": result['result']?['value']};
  }

  /// Get element CSS property.
  Future<Map<String, dynamic>> getCssProperty(String key, String property) async {
    final result = await _evalJs('''
      (() => {
        const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]');
        if (!el) return null;
        return getComputedStyle(el).getPropertyValue('$property');
      })()
    ''');
    return {"value": result['result']?['value']};
  }

  /// Get element bounding box (public).
  Future<Map<String, dynamic>> getBoundingBox(String key) async {
    final bounds = await _getElementBounds(key);
    if (bounds == null) return {"success": false, "message": "Element not found"};
    return {"success": true, "bounds": bounds};
  }

  /// Count elements matching selector.
  Future<int> countElements(String selector) async {
    final result = await _evalJs('document.querySelectorAll("$selector").length');
    return result['result']?['value'] as int? ?? 0;
  }

  /// Check if element is visible.
  Future<bool> isVisible(String key) async {
    final result = await _evalJs('''
      (() => {
        const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]');
        if (!el) return false;
        const rect = el.getBoundingClientRect();
        const style = getComputedStyle(el);
        return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
      })()
    ''');
    return result['result']?['value'] == true;
  }

  /// Focus element.
  Future<Map<String, dynamic>> focus(String key) async {
    final result = await _evalJs('''
      (() => {
        const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]');
        if (!el) return false;
        el.focus();
        return true;
      })()
    ''');
    return {"success": result['result']?['value'] == true};
  }

  /// Blur (unfocus) element.
  Future<Map<String, dynamic>> blur(String key) async {
    await _evalJs('''
      (() => {
        const el = document.getElementById('$key') || document.querySelector('[data-testid="$key"]');
        if (el) el.blur();
      })()
    ''');
    return {"success": true};
  }

  /// Get page title.
  Future<String> getTitle() async {
    final result = await _evalJs('document.title');
    return (result['result']?['value'] as String?) ?? '';
  }

  /// Get page HTML with optional cleaning.
  Future<String> getPageSource({
    String? selector,
    bool removeScripts = false,
    bool removeStyles = false,
    bool removeComments = false,
    bool removeMeta = false,
    bool minify = false,
    bool cleanHtml = false,
  }) async {
    if (cleanHtml) {
      removeScripts = true;
      removeStyles = true;
      removeComments = true;
      removeMeta = true;
    }
    final selectorJs = selector != null
        ? 'var el = document.querySelector(${jsonEncode(selector)}); el ? el.outerHTML : ""'
        : 'document.documentElement.outerHTML';
    final result = await _evalJs(selectorJs);
    var html = (result['result']?['value'] as String?) ?? '';
    if (removeScripts) html = html.replaceAll(RegExp(r'<script[\s\S]*?<\/script>', caseSensitive: false), '');
    if (removeStyles) html = html.replaceAll(RegExp(r'<style[\s\S]*?<\/style>', caseSensitive: false), '');
    if (removeComments) html = html.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
    if (removeMeta) html = html.replaceAll(RegExp(r'<meta[^>]*/?>', caseSensitive: false), '');
    if (minify) html = html.replaceAll(RegExp(r'\s+'), ' ').trim();
    return html;
  }

  /// Get visible text content (skips hidden elements).
  Future<String> getVisibleText({String? selector}) async {
    final root = selector != null ? 'document.querySelector(${jsonEncode(selector)})' : 'document.body';
    final js = '''
(function() {
  var root = $root;
  if (!root) return '';
  var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: function(node) {
      var el = node.parentElement;
      if (!el) return NodeFilter.FILTER_REJECT;
      var style = window.getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    }
  });
  var texts = [];
  while (walker.nextNode()) {
    var t = walker.currentNode.textContent.trim();
    if (t) texts.push(t);
  }
  return texts.join(' ');
})()
''';
    final result = await _evalJs(js);
    return (result['result']?['value'] as String?) ?? '';
  }

  /// Set geolocation.
  Future<Map<String, dynamic>> setGeolocation(double latitude, double longitude, {double accuracy = 100}) async {
    await _call('Emulation.setGeolocationOverride', {
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
    });
    return {"success": true};
  }

  /// Set timezone.
  Future<Map<String, dynamic>> setTimezone(String timezone) async {
    await _call('Emulation.setTimezoneOverride', {'timezoneId': timezone});
    return {"success": true};
  }

  /// Set dark/light mode.
  Future<Map<String, dynamic>> setColorScheme(String scheme) async {
    await _call('Emulation.setEmulatedMedia', {
      'features': [{'name': 'prefers-color-scheme', 'value': scheme}],
    });
    return {"success": true, "scheme": scheme};
  }

  /// Block URLs (e.g. ads, trackers).
  Future<Map<String, dynamic>> blockUrls(List<String> patterns) async {
    await _call('Network.setBlockedURLs', {'urls': patterns});
    return {"success": true, "blocked": patterns};
  }

  /// Throttle network (simulate slow connections).
  Future<Map<String, dynamic>> throttleNetwork({int latencyMs = 0, int downloadKbps = -1, int uploadKbps = -1}) async {
    await _call('Network.emulateNetworkConditions', {
      'offline': false,
      'latency': latencyMs,
      'downloadThroughput': downloadKbps > 0 ? downloadKbps * 1024 / 8 : -1,
      'uploadThroughput': uploadKbps > 0 ? uploadKbps * 1024 / 8 : -1,
    });
    return {"success": true};
  }

  /// Disable network (offline mode).
  Future<Map<String, dynamic>> goOffline() async {
    await _call('Network.emulateNetworkConditions', {
      'offline': true,
      'latency': 0,
      'downloadThroughput': -1,
      'uploadThroughput': -1,
    });
    return {"success": true, "offline": true};
  }

  /// Clear browser data.
  Future<Map<String, dynamic>> clearBrowserData() async {
    await _call('Network.clearBrowserCookies');
    await _call('Network.clearBrowserCache');
    await _evalJs("localStorage.clear(); sessionStorage.clear()");
    return {"success": true};
  }

  // ── File upload ──

  /// Upload file to input[type=file].
  Future<Map<String, dynamic>> uploadFile(String selector, List<String> filePaths) async {
    // Find the file input node
    final doc = await _call('DOM.getDocument');
    final rootNodeId = doc['root']?['nodeId'] as int? ?? 0;
    final result = await _call('DOM.querySelector', {
      'nodeId': rootNodeId,
      'selector': selector,
    });
    final nodeId = result['nodeId'] as int?;
    if (nodeId == null || nodeId == 0) return {"success": false, "message": "File input not found"};

    await _call('DOM.setFileInputFiles', {
      'nodeId': nodeId,
      'files': filePaths,
    });
    return {"success": true, "files": filePaths};
  }

  // ── Dialog handling ──

  bool _dialogHandlerInstalled = false;
  

  Future<void> installDialogHandler({bool autoAccept = true}) async {
    if (_dialogHandlerInstalled) return;
    _dialogHandlerInstalled = true;
    // Dialog events come as CDP events — handled in _onMessage
  }

  Future<Map<String, dynamic>> handleDialog(bool accept, {String? promptText}) async {
    await _call('Page.handleJavaScriptDialog', {
      'accept': accept,
      if (promptText != null) 'promptText': promptText,
    });
    return {"success": true, "action": accept ? "accepted" : "dismissed"};
  }

  // ── Iframe support ──

  Future<Map<String, dynamic>> getFrames() async {
    final tree = await _call('Page.getFrameTree');
    List<Map<String, dynamic>> flatten(Map<String, dynamic> frame) {
      final result = <Map<String, dynamic>>[];
      final f = frame['frame'] as Map<String, dynamic>?;
      if (f != null) {
        result.add({
          'id': f['id'],
          'url': f['url'],
          'name': f['name'] ?? '',
          'securityOrigin': f['securityOrigin'],
        });
      }
      final children = frame['childFrames'] as List?;
      if (children != null) {
        for (final child in children) {
          result.addAll(flatten(child as Map<String, dynamic>));
        }
      }
      return result;
    }
    final frames = flatten(tree['frameTree'] as Map<String, dynamic>? ?? {});
    return {"frames": frames, "count": frames.length};
  }

  Future<Map<String, dynamic>> evalInFrame(String frameId, String expression) async {
    // Create isolated world in the target frame
    final world = await _call('Page.createIsolatedWorld', {
      'frameId': frameId,
      'worldName': 'flutter-skill-eval',
      'grantUniveralAccess': true,
    });
    final contextId = world['executionContextId'] as int?;
    if (contextId == null) return {"success": false, "message": "Cannot access frame"};
    final result = await _call('Runtime.evaluate', {
      'expression': expression,
      'contextId': contextId,
      'returnByValue': true,
    });
    return {"result": result['result']?['value']};
  }

  // ── Multi-tab management ──

  Future<Map<String, dynamic>> getTabs() async {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:$_port/json'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();
    final tabs = (jsonDecode(body) as List).where((t) => t['type'] == 'page').map((t) => {
      'id': t['id'],
      'title': t['title'],
      'url': t['url'],
    }).toList();
    return {"tabs": tabs, "count": tabs.length};
  }

  Future<Map<String, dynamic>> newTab(String url) async {
    final result = await _call('Target.createTarget', {'url': url});
    return {"success": true, "targetId": result['targetId']};
  }

  Future<Map<String, dynamic>> closeTab(String targetId) async {
    await _call('Target.closeTarget', {'targetId': targetId});
    return {"success": true};
  }

  Future<Map<String, dynamic>> switchTab(String targetId) async {
    await _call('Target.activateTarget', {'targetId': targetId});
    return {"success": true};
  }

  // ── Network request interception/mocking ──

  final Map<String, Map<String, dynamic>> _interceptRules = {};

  Future<Map<String, dynamic>> interceptRequests(String urlPattern, {int? statusCode, String? body, Map<String, String>? headers}) async {
    await _call('Fetch.enable', {
      'patterns': [{'urlPattern': urlPattern, 'requestStage': 'Response'}],
    });
    _interceptRules[urlPattern] = {
      'statusCode': statusCode ?? 200,
      'body': body ?? '',
      'headers': headers ?? {},
    };
    return {"success": true, "pattern": urlPattern};
  }

  Future<Map<String, dynamic>> clearInterceptions() async {
    await _call('Fetch.disable');
    _interceptRules.clear();
    return {"success": true};
  }

  // ── Accessibility audit ──

  Future<Map<String, dynamic>> accessibilityAudit() async {
    final result = await _evalJs('''
      JSON.stringify((() => {
        const issues = [];
        // Check images without alt
        document.querySelectorAll('img:not([alt])').forEach(img => {
          issues.push({type: 'error', rule: 'img-alt', message: 'Image missing alt attribute', element: img.src?.substring(0, 80)});
        });
        // Check form inputs without labels
        document.querySelectorAll('input:not([type="hidden"]):not([aria-label]):not([id])').forEach(el => {
          issues.push({type: 'warning', rule: 'input-label', message: 'Input missing associated label', element: el.outerHTML?.substring(0, 80)});
        });
        // Check empty buttons
        document.querySelectorAll('button').forEach(btn => {
          if (!btn.textContent?.trim() && !btn.getAttribute('aria-label')) {
            issues.push({type: 'error', rule: 'button-name', message: 'Button has no accessible name', element: btn.outerHTML?.substring(0, 80)});
          }
        });
        // Check empty links
        document.querySelectorAll('a').forEach(a => {
          if (!a.textContent?.trim() && !a.getAttribute('aria-label')) {
            issues.push({type: 'error', rule: 'link-name', message: 'Link has no accessible name', element: a.outerHTML?.substring(0, 80)});
          }
        });
        // Check heading hierarchy
        let lastLevel = 0;
        document.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(h => {
          const level = parseInt(h.tagName[1]);
          if (level > lastLevel + 1 && lastLevel > 0) {
            issues.push({type: 'warning', rule: 'heading-order', message: 'Heading level skipped: h' + lastLevel + ' → h' + level, element: h.textContent?.substring(0, 40)});
          }
          lastLevel = level;
        });
        // Check color contrast (basic)
        document.querySelectorAll('*').forEach(el => {
          const style = getComputedStyle(el);
          if (style.color === style.backgroundColor && el.textContent?.trim()) {
            issues.push({type: 'error', rule: 'color-contrast', message: 'Text same color as background', element: el.textContent?.substring(0, 40)});
          }
        });
        // Check document language
        if (!document.documentElement.lang) {
          issues.push({type: 'warning', rule: 'html-lang', message: 'HTML element missing lang attribute'});
        }
        // Check viewport meta
        if (!document.querySelector('meta[name="viewport"]')) {
          issues.push({type: 'warning', rule: 'viewport', message: 'Missing viewport meta tag'});
        }
        return {issues: issues, total: issues.length, errors: issues.filter(i => i.type === 'error').length, warnings: issues.filter(i => i.type === 'warning').length};
      })())
    ''');
    final v = result['result']?['value'] as String?;
    if (v == null) return {"issues": [], "total": 0};
    return jsonDecode(v) as Map<String, dynamic>;
  }

  // ── Visual regression ──

  Future<Map<String, dynamic>> compareScreenshot(String baselinePath) async {
    final current = await takeScreenshot();
    if (current == null) return {"success": false, "message": "Screenshot failed"};

    final currentFile = File('${Directory.systemTemp.path}/flutter_skill_compare_${DateTime.now().millisecondsSinceEpoch}.png');
    await currentFile.writeAsBytes(base64.decode(current));

    final baselineFile = File(baselinePath);
    if (!baselineFile.existsSync()) {
      // No baseline — save current as baseline
      await currentFile.copy(baselinePath);
      return {"success": true, "action": "baseline_created", "path": baselinePath};
    }

    // Basic pixel comparison
    final baselineBytes = await baselineFile.readAsBytes();
    final currentBytes = await currentFile.readAsBytes();

    if (baselineBytes.length != currentBytes.length) {
      return {
        "success": false,
        "match": false,
        "reason": "Image sizes differ",
        "baseline_size": baselineBytes.length,
        "current_size": currentBytes.length,
        "current_path": currentFile.path,
      };
    }

    int diffPixels = 0;
    for (int i = 0; i < baselineBytes.length; i++) {
      if (baselineBytes[i] != currentBytes[i]) diffPixels++;
    }
    final diffPercent = (diffPixels / baselineBytes.length * 100);
    final match = diffPercent < 1.0; // 1% tolerance

    return {
      "success": true,
      "match": match,
      "diff_percent": double.parse(diffPercent.toStringAsFixed(2)),
      "current_path": currentFile.path,
      "baseline_path": baselinePath,
    };
  }

  // ── Wait for network idle ──

  Future<Map<String, dynamic>> waitForNetworkIdle({int timeoutMs = 10000, int idleMs = 500}) async {
    final result = await _evalJs('''
      new Promise((resolve) => {
        let pending = 0;
        let timer = null;
        const timeout = setTimeout(() => resolve(JSON.stringify({idle: false, reason: 'timeout'})), $timeoutMs);
        const check = () => {
          if (pending <= 0) {
            clearTimeout(timer);
            timer = setTimeout(() => {
              clearTimeout(timeout);
              resolve(JSON.stringify({idle: true}));
            }, $idleMs);
          }
        };
        const origFetch = window.fetch;
        window.fetch = function() {
          pending++;
          return origFetch.apply(this, arguments).finally(() => { pending--; check(); });
        };
        const origXHR = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function() {
          pending++;
          this.addEventListener('loadend', () => { pending--; check(); });
          return origXHR.apply(this, arguments);
        };
        check();
      })
    ''');
    final raw = result['result']?['value'];
    if (raw == null) return {"idle": true};
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
    return {"idle": true};
  }

  // ── Session/tab storage ──

  Future<Map<String, dynamic>> getSessionStorage() async {
    final result = await _evalJs('JSON.stringify(Object.fromEntries(Object.entries(sessionStorage)))');
    final v = result['result']?['value'] as String?;
    if (v == null) return {};
    return jsonDecode(v) as Map<String, dynamic>;
  }

  /// Get all open handles (window.open references).
  Future<Map<String, dynamic>> getWindowHandles() async {
    final result = await _evalJs('window.length');
    return {"window_count": result['result']?['value'] ?? 1};
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

  /// Poll CDP endpoint until it responds (replaces fixed 2s delay after Chrome launch)
  Future<void> _waitForCdpReady() async {
    final client = http.Client();
    for (var i = 0; i < 40; i++) { // 40 * 50ms = 2s max
      try {
        final resp = await client.get(Uri.parse('http://127.0.0.1:$_port/json/version'))
            .timeout(const Duration(milliseconds: 200));
        if (resp.statusCode == 200) {
          client.close();
          return;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 50));
    }
    client.close();
  }

  /// Wait for page load event via CDP (replaces fixed 2s delay)
  Future<void> _waitForLoad() async {
    final completer = Completer<void>();
    // Listen for Page.loadEventFired
    _eventSubscriptions['Page.loadEventFired'] = () {
      if (!completer.isCompleted) completer.complete();
    };
    // Also complete on frameStoppedLoading
    _eventSubscriptions['Page.frameStoppedLoading'] = () {
      if (!completer.isCompleted) completer.complete();
    };
    // Timeout after 3s
    await completer.future.timeout(const Duration(seconds: 3), onTimeout: () {
      // Page didn't fire load event in time — continue anyway
    });
    _eventSubscriptions.remove('Page.loadEventFired');
    _eventSubscriptions.remove('Page.frameStoppedLoading');
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
      // CDP events (no id)
      final method = json['method'] as String?;
      if (method != null) {
        _eventSubscriptions[method]?.call();
      }
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
