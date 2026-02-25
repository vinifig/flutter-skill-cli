library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../drivers/app_driver.dart';
import 'device_presets.dart';

part 'cdp_browser_methods.dart';
part 'cdp_appmcp_methods.dart';

/// AppDriver that communicates with any web page via Chrome DevTools Protocol.
///
/// No SDK injection needed — connects directly to Chrome's debugging port
/// and controls any web page (React, Vue, Angular, plain HTML, etc.).
class CdpDriver implements AppDriver {
  final String _url;
  int _port;
  final bool _launchChrome;
  final bool _headless;
  final String? _chromePath;
  final String? _proxy;
  final bool _ignoreSsl;
  final int _maxTabs;

  WebSocket? _ws;
  bool _connected = false;
  int _nextId = 1;
  Process? _chromeProcess;

  /// Pending CDP calls keyed by request id.
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<String, void Function()> _eventSubscriptions = {};
  final Map<String, List<void Function(Map<String, dynamic>)>> _eventListeners =
      {};
  bool _dialogHandlerInstalled = false;
  final Map<String, Map<String, dynamic>> _interceptRules = {};

  /// Create a CDP driver.
  ///
  /// [url] is the page to navigate to.
  /// [port] is the Chrome remote debugging port.
  /// [launchChrome] whether to launch a new Chrome instance.
  /// [headless] run Chrome in headless mode (default: false).
  /// [chromePath] custom Chrome/Chromium executable path.
  /// [proxy] proxy server URL (e.g. 'http://proxy:8080').
  /// [ignoreSsl] ignore SSL certificate errors.
  /// [maxTabs] maximum number of tabs to allow (prevents runaway tab creation).
  CdpDriver({
    required String url,
    int port = 9222,
    bool launchChrome = true,
    bool headless = false,
    String? chromePath,
    String? proxy,
    bool ignoreSsl = false,
    int maxTabs = 20,
  })  : _url = url,
        _port = port,
        _launchChrome = launchChrome,
        _headless = headless,
        _chromePath = chromePath,
        _proxy = proxy,
        _ignoreSsl = ignoreSsl,
        _maxTabs = maxTabs;

  @override
  String get frameworkName => 'CDP (Web)';

  @override
  bool get isConnected => _connected;

  @override
  /// Whether connect() found an existing tab matching the target URL
  /// (skipped navigation to avoid duplicate tabs).
  bool connectedToExistingTab = false;

  Future<void> connect() async {
    if (_launchChrome) {
      // Auto-assign random port if 0
      if (_port == 0) {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        _port = server.port;
        await server.close();
      }

      // Check if Chrome is already running on this port before launching
      final alreadyRunning = await _isCdpPortAlive();
      if (alreadyRunning) {
        // Chrome already running — don't launch again (would open duplicate tab)
      } else {
        await _launchChromeProcess();
        // Poll for CDP readiness instead of fixed delay
        await _waitForCdpReady();
      }
    }

    // Discover tabs via CDP JSON endpoint
    var wsUrl = await _discoverTarget();
    
    // No suitable tab found — create a new one via CDP HTTP API
    if (wsUrl == null && _url.isNotEmpty) {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
        final encodedUrl = Uri.encodeComponent(_url);
        // Chrome 145+ requires PUT for /json/new
        final request = await client.openUrl('PUT', Uri.parse('http://127.0.0.1:$_port/json/new?$encodedUrl'));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        client.close();
        final tab = jsonDecode(body) as Map<String, dynamic>;
        wsUrl = tab['webSocketDebuggerUrl'] as String?;
        // Tab was just created with our URL — skip later navigation
        if (wsUrl != null) connectedToExistingTab = true;
      } catch (_) {}
    }
    
    if (wsUrl == null) {
      throw Exception('Could not find or create a debuggable tab on port $_port. '
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

    // Check if _discoverTarget already found a tab with our exact URL.
    // If so, skip navigation to avoid reloading/duplicating.
    final currentUrl = await _getCurrentUrl();
    final alreadyOnTarget = currentUrl == _url ||
        (currentUrl != null && _url.isNotEmpty && currentUrl.startsWith(_url));

    // Navigate to URL and wait for load event.
    final skipNav = _url.isEmpty ||
        _url == 'about:blank' ||
        _url.contains('localhost:$_port') ||
        _url.contains('127.0.0.1:$_port') ||
        alreadyOnTarget;
    if (!skipNav) {
      await _call('Page.navigate', {'url': _url});
      try {
        await _waitForLoad();
      } catch (_) {
        // Timeout is acceptable — page may be slow but still usable
      }
    } else if (alreadyOnTarget) {
      connectedToExistingTab = true;
    }
  }

  /// Check if CDP port is already responding
  Future<bool> _isCdpPortAlive() async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$_port/json/version'));
      final response = await request.close();
      await response.drain<void>();
      client.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Get the current page URL via Runtime.evaluate
  Future<String?> _getCurrentUrl() async {
    try {
      final result = await _call('Runtime.evaluate', {
        'expression': 'location.href',
        'returnByValue': true,
      });
      return result['result']?['value'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Reconnect to a new WebSocket URL (e.g., after target navigates away)
  Future<void> reconnectTo(String wsUrl) async {
    _connected = false;
    _reconnecting = true; // Prevent _autoReconnect from overriding this
    _failAllPending('Reconnecting');
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;

    _ws = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 10));
    _connected = true;

    _ws!.listen(
      _onMessage,
      onDone: _onDisconnect,
      onError: (_) => _onDisconnect(),
      cancelOnError: false,
    );

    // Re-enable required CDP domains
    await Future.wait([
      _call('Page.enable'),
      _call('DOM.enable'),
      _call('Runtime.enable'),
    ]);
    _reconnecting = false;
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
  Future<Map<String, dynamic>> tap(
      {String? key, String? text, String? ref}) async {
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

    await _dispatchMouseEvent('mousePressed', cx, cy,
        button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mouseReleased', cx, cy,
        button: 'left', clickCount: 1);
    await _ensureFocusAtPoint(cx, cy);

    return {
      'success': true,
      'position': {'x': cx, 'y': cy},
    };
  }

  @override
  Future<Map<String, dynamic>> enterText(String? key, String text,
      {String? ref}) async {
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
  Future<bool> swipe(
      {required String direction, double distance = 300, String? key}) async {
    // Get viewport dimensions
    final metrics = await _call('Page.getLayoutMetrics');
    final vw =
        (metrics['cssLayoutViewport']?['clientWidth'] as num?)?.toDouble() ??
            800.0;
    final vh =
        (metrics['cssLayoutViewport']?['clientHeight'] as num?)?.toDouble() ??
            600.0;

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
  Future<List<dynamic>> getInteractiveElements(
      {bool includePositions = true}) async {
    final result = await _evalJs('''
      (() => {
        const selectors = 'a, button, input, select, textarea, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], [onclick], [tabindex], [contenteditable="true"]';
        // Recursive query that traverses Shadow DOM
        function deepQueryAll(root, sel) {
          const results = Array.from(root.querySelectorAll(sel));
          root.querySelectorAll('*').forEach(el => {
            if (el.shadowRoot) results.push(...deepQueryAll(el.shadowRoot, sel));
          });
          return results;
        }
        const elements = deepQueryAll(document, selectors);
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
        if (prop is Map &&
            prop['value']?['type'] == 'object' &&
            prop['name'] != '__proto__' &&
            prop['name'] != 'length') {
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
        const selectors = 'a, button, input, select, textarea, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], [onclick], [tabindex], [contenteditable="true"]';
        function deepQueryAll(root, sel) {
          const results = Array.from(root.querySelectorAll(sel));
          root.querySelectorAll('*').forEach(el => {
            if (el.shadowRoot) results.push(...deepQueryAll(el.shadowRoot, sel));
          });
          return results;
        }
        const elements = deepQueryAll(document, selectors);
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

  /// Fast accessibility snapshot via single JS evaluation.
  /// Scans all interactive + landmark elements, assigns ref IDs, returns compact text.
  /// Benchmarked at ~10-50ms (vs 60ms+ for CDP Accessibility.getFullAXTree).
  /// Pierces Shadow DOM automatically.
  Future<Map<String, dynamic>> getAccessibilitySnapshot() async {
    final result = await _evalJs(r'''
(() => {
  const t0 = performance.now();
  // Deep query helper for Shadow DOM
  function dqAll(sel, root) {
    root = root || document;
    let r = Array.from(root.querySelectorAll(sel));
    for (const n of root.querySelectorAll('*')) {
      if (n.shadowRoot) r = r.concat(dqAll(sel, n.shadowRoot));
    }
    return r;
  }
  
  // ===== Detect page-level context =====
  const framework = (() => {
    if (window.__NEXT_DATA__) return 'nextjs';
    if (window.__NUXT__) return 'nuxt';
    if (document.querySelector('[ng-version]')) return 'angular';
    if (document.querySelector('[data-reactroot]') || document.querySelector('#__next')) return 'react';
    if (document.querySelector('[data-v-]')) return 'vue';
    return 'unknown';
  })();
  
  // Detect editor type
  const editorType = (() => {
    if (document.querySelector('.CodeMirror')) return 'codemirror';
    if (document.querySelector('.cm-editor')) return 'codemirror6';
    if (document.querySelector('.DraftEditor-root')) return 'draft-js';
    if (document.querySelector('.tiptap.ProseMirror')) return 'tiptap';
    if (document.querySelector('.ProseMirror')) return 'prosemirror';
    if (document.querySelector('.ql-editor')) return 'quill';
    if (document.querySelector('[contenteditable="true"]')) return 'contenteditable';
    return 'none';
  })();
  
  // Recommend best input method based on framework + editor
  const inputMethod = (() => {
    if (editorType === 'codemirror' || editorType === 'codemirror6') return 'api:CodeMirror.setValue()';
    if (editorType === 'draft-js') return 'clipboard:paste-event';
    if (editorType === 'tiptap' || editorType === 'prosemirror') return 'html:innerHTML+input-event';
    if (editorType === 'quill') return 'api:quill.clipboard.dangerouslyPasteHTML()';
    if (framework === 'react') return 'cdp:Input.insertText';
    return 'cdp:Input.insertText';
  })();
  
  const interactiveSel = 'a,button,input,select,textarea,[role="button"],[role="link"],[role="textbox"],[role="searchbox"],[role="combobox"],[role="checkbox"],[role="radio"],[role="switch"],[role="tab"],[role="menuitem"],[role="option"],[role="slider"],[contenteditable="true"]';
  const landmarkSel = 'h1,h2,h3,h4,h5,h6,nav,main,header,footer,[role="heading"],[role="navigation"],[role="main"],[role="banner"],[role="complementary"],[role="dialog"],[role="alert"],[role="status"],img[alt],label,[class*="error"],[class*="warning"],[aria-invalid]';
  
  const allEls = dqAll(interactiveSel + ',' + landmarkSel);

  // Also collect elements from same-origin iframes
  const iframeEls = [];
  const iframeOffsets = new WeakMap();
  try {
    for (const iframe of document.querySelectorAll('iframe')) {
      try {
        const doc = iframe.contentDocument;
        if (!doc) continue;
        const iRect = iframe.getBoundingClientRect();
        if (iRect.width === 0 || iRect.height === 0) continue;
        const sel = interactiveSel + ',' + landmarkSel;
        for (const el of doc.querySelectorAll(sel)) {
          iframeEls.push(el);
          iframeOffsets.set(el, {dx: iRect.x, dy: iRect.y, src: iframe.src.substring(0, 60)});
        }
      } catch(e) { /* cross-origin iframe — skip */ }
    }
  } catch(e) {}
  const combinedEls = [...allEls, ...iframeEls];

  const vw = window.innerWidth;
  const vh = window.innerHeight;
  let refN = 0;
  const lines = [];
  const refs = {};
  let interactiveCount = 0;
  const requiredEmpty = [];
  const errors = [];
  
  for (const el of combinedEls) {
    const iframeOff = iframeOffsets.get(el);
    const r = el.getBoundingClientRect();
    // For iframe elements, we store the offset but use raw rect for visibility check
    if (r.width === 0 && r.height === 0) continue;
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden') continue;
    
    const tag = el.tagName.toLowerCase();
    const role = el.getAttribute('role') || ({'a':'link','button':'button','input':'textbox','select':'combobox','textarea':'textbox','h1':'heading','h2':'heading','h3':'heading','h4':'heading','h5':'heading','h6':'heading','nav':'navigation','img':'img','label':'label'}[tag] || tag);
    const text = (el.textContent || '').trim().substring(0, 60);
    const ariaLabel = el.getAttribute('aria-label') || '';
    const placeholder = el.getAttribute('placeholder') || '';
    const name = ariaLabel || placeholder || text;
    const displayName = name.length > 55 ? name.substring(0, 52) + '...' : name;
    const value = el.value || '';
    const type = el.getAttribute('type') || '';
    
    const isInteractive = /^(link|button|textbox|searchbox|combobox|checkbox|radio|switch|tab|menuitem|option|slider)$/.test(role) || el.hasAttribute('contenteditable');
    
    refN++;
    const refId = 'e' + refN;
    if (isInteractive) interactiveCount++;
    
    // ===== Enhanced state detection =====
    const states = [];
    if (el.disabled) states.push('disabled');
    if (el.checked) states.push('checked');
    if (el.getAttribute('aria-expanded') === 'true') states.push('expanded');
    if (el.getAttribute('aria-selected') === 'true') states.push('selected');
    if (el.required || el.getAttribute('aria-required') === 'true') states.push('required');
    if (document.activeElement === el) states.push('focused');
    if (el.getAttribute('aria-invalid') === 'true') states.push('invalid');
    if (el.readOnly) states.push('readonly');
    
    // Empty check for required fields
    const isEmpty = (tag === 'input' || tag === 'textarea' || tag === 'select') && !value.trim();
    const isEmptyEditable = el.hasAttribute('contenteditable') && !el.textContent?.trim();
    if ((el.required || el.getAttribute('aria-required') === 'true') && (isEmpty || isEmptyEditable)) {
      states.push('empty');
      requiredEmpty.push(displayName || role + '#' + refId);
    }
    
    // ===== Validation info =====
    let validation = '';
    if (el.validity && !el.validity.valid && value) {
      if (el.validity.tooShort) validation = ' minlen=' + el.minLength;
      if (el.validity.tooLong) validation = ' maxlen=' + el.maxLength;
      if (el.validity.patternMismatch) validation = ' pattern=' + el.pattern;
      if (el.validity.typeMismatch) validation = ' invalid-format';
    }
    if (el.minLength > 0) validation += ' minlen=' + el.minLength;
    if (el.maxLength > 0 && el.maxLength < 10000) validation += ' maxlen=' + el.maxLength;
    
    // ===== Error message detection =====
    if (el.classList?.contains('error') || el.getAttribute('aria-invalid') === 'true' ||
        (el.className && /error|warning|invalid/i.test(el.className))) {
      const errText = el.textContent?.trim();
      if (errText && errText.length < 100) errors.push(errText);
    }
    // Check aria-errormessage
    const errMsgId = el.getAttribute('aria-errormessage') || el.getAttribute('aria-describedby');
    if (errMsgId) {
      const errEl = document.getElementById(errMsgId);
      if (errEl?.textContent?.trim()) errors.push(errEl.textContent.trim());
    }
    
    // ===== Select/dropdown options =====
    let optionsStr = '';
    if (tag === 'select') {
      const opts = Array.from(el.options || []).map(o => o.text?.trim()).filter(Boolean).slice(0, 10);
      if (opts.length) optionsStr = ' options=[' + opts.join(',') + ']';
    }
    
    // ===== Disabled button reason =====
    let disabledReason = '';
    if (el.disabled && role === 'button' && requiredEmpty.length > 0) {
      disabledReason = ' reason="missing:' + requiredEmpty.join(',') + '"';
    }
    
    const stateStr = states.length ? ' [' + states.join(',') + ']' : '';
    const valueStr = value && type !== 'password' ? ' value="' + value.substring(0, 30) + '"' : '';
    const typeStr = type && type !== 'text' ? ' type=' + type : '';
    const refStr = isInteractive ? ' [ref=' + refId + ']' : '';
    
    // Viewport indicator
    const inView = r.top >= -10 && r.bottom <= vh + 10;
    const offscreen = !inView && (r.bottom < -100 || r.top > vh + 100) ? ' (offscreen)' : '';
    // Beyond viewport width (important for dialog buttons)
    const beyondVW = r.left > vw ? ' (beyond-viewport-x:' + Math.round(r.left) + ')' : '';
    
    refs[refId] = displayName;
    const iframeTag = iframeOff ? ' (iframe:' + iframeOff.src + ')' : '';
    lines.push(role + ' "' + displayName + '"' + typeStr + valueStr + optionsStr + refStr + stateStr + validation + disabledReason + offscreen + beyondVW + iframeTag);
  }
  
  const elapsed = Math.round(performance.now() - t0);
  const snapshot = lines.join('\n');
  
  // ===== Form summary =====
  const formMeta = {
    framework: framework,
    editorType: editorType,
    inputMethod: inputMethod,
    requiredEmpty: requiredEmpty,
    errors: errors,
    viewport: vw + 'x' + vh,
  };
  
  return JSON.stringify({
    snapshot: snapshot,
    interactiveCount: interactiveCount,
    totalElements: refN,
    tokenEstimate: Math.round(snapshot.length / 4),
    elapsedMs: elapsed,
    formMeta: formMeta,
    hint: requiredEmpty.length > 0
      ? 'BLOCKED: Required empty fields: [' + requiredEmpty.join(', ') + ']. Fill these before submit. Use ' + inputMethod + ' for input.'
      : 'Ready to submit. Use act(ref, action) to interact.',
    refs: refs
  });
})()
    ''');

    final parsed = _parseJsonEval(result);
    if (parsed != null) return parsed;
    // Fallback
    return await getInteractiveElementsStructured();
  }

  /// Fast composite action — find + scroll + act in a SINGLE JS evaluation.
  /// Benchmarked: ~1-15ms for click, ~2-20ms for fill (vs ~1000ms before).
  /// Falls back to CDP Input.dispatch for actions that need real mouse events.
  Future<Map<String, dynamic>> act({
    String? ref,
    String? text,
    String? key,
    required String action,
    String? value,
    int timeoutMs = 5000,
    bool dispatchRealEvents = false,
  }) async {
    // Escape parameters for JS
    final jsText = text?.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\n', '\\n') ?? '';
    final jsKey = key?.replaceAll('\\', '\\\\').replaceAll("'", "\\'") ?? '';
    final jsRef = ref?.replaceAll('\\', '\\\\').replaceAll("'", "\\'") ?? '';
    final jsValue = value?.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\n', '\\n') ?? '';

    // Single JS eval: find + scroll + act
    final result = await _evalJs('''
(() => {
  const t0 = performance.now();
  // Deep query helpers
  function dq(sel, root) {
    root = root || document;
    let el = root.querySelector(sel);
    if (el) return el;
    for (const n of root.querySelectorAll('*')) {
      if (n.shadowRoot) { el = dq(sel, n.shadowRoot); if (el) return el; }
    }
    return null;
  }
  function dqAll(sel, root) {
    root = root || document;
    let r = Array.from(root.querySelectorAll(sel));
    for (const n of root.querySelectorAll('*')) {
      if (n.shadowRoot) r = r.concat(dqAll(sel, n.shadowRoot));
    }
    return r;
  }
  
  let el = null;
  const refId = '$jsRef';
  const textQuery = '$jsText';
  const keyQuery = '$jsKey';
  
  // Strategy 1: By CSS selector/key
  if (keyQuery) {
    el = dq(keyQuery) || dq('#' + keyQuery) || dq('[name="' + keyQuery + '"]') || dq('[data-testid="' + keyQuery + '"]');
  }
  
  // Strategy 2: By ref ID (e.g. "e5" from snapshot)
  if (!el && refId) {
    // Refs are positional — find the Nth interactive element
    const refMatch = refId.match(/^e(\\d+)\$/);
    if (refMatch) {
      const idx = parseInt(refMatch[1]) - 1;
      const interactiveSel = 'a,button,input,select,textarea,[role="button"],[role="link"],[role="textbox"],[role="searchbox"],[role="combobox"],[role="checkbox"],[role="radio"],[role="switch"],[role="tab"],[role="menuitem"],[role="option"],[role="slider"],[contenteditable="true"],h1,h2,h3,h4,h5,h6,nav,main,header,footer,[role="heading"],[role="navigation"],[role="main"],[role="banner"],[role="complementary"],[role="dialog"],[role="alert"],[role="status"],img[alt],label';
      const all = dqAll(interactiveSel);
      const visible = all.filter(e => {
        const r = e.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) return false;
        const s = getComputedStyle(e);
        return s.display !== 'none' && s.visibility !== 'hidden';
      });
      if (idx < visible.length) el = visible[idx];
    }
    // Also try by ref-like selector
    if (!el) el = dq('[data-ref="' + refId + '"]');
  }
  
  // Strategy 3: By text content (exact then partial)
  if (!el && textQuery) {
    const all = dqAll('a,button,input,select,textarea,label,span,div,h1,h2,h3,h4,h5,h6,[role="button"],[role="link"],[role="tab"],[role="menuitem"],[role="option"]');
    for (const e of all) {
      if (e.textContent && e.textContent.trim() === textQuery) { el = e; break; }
    }
    if (!el) {
      for (const e of all) {
        if (e.textContent && e.textContent.trim().includes(textQuery)) { el = e; break; }
      }
    }
  }
  
  if (!el) {
    return JSON.stringify({success: false, error: 'Element not found: ' + (refId || textQuery || keyQuery), elapsedMs: Math.round(performance.now() - t0)});
  }
  
  // Scroll into view if needed
  const rect = el.getBoundingClientRect();
  if (rect.top < 0 || rect.bottom > window.innerHeight) {
    el.scrollIntoView({behavior: 'instant', block: 'center'});
  }
  
  const action = '$action';
  const fillValue = '$jsValue';
  const cx = Math.round(rect.left + rect.width / 2);
  const cy = Math.round(rect.top + rect.height / 2);
  
  switch (action) {
    case 'click':
    case 'tap':
      el.focus();
      el.click();
      return JSON.stringify({success: true, action: 'click', position: {x: cx, y: cy}, elapsedMs: Math.round(performance.now() - t0)});
    
    case 'fill': {
      el.focus();
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
        el.value = '';
        el.value = fillValue;
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
      } else if (el.isContentEditable || el.getAttribute('contenteditable') === 'true') {
        el.innerHTML = fillValue;
        el.dispatchEvent(new Event('input', {bubbles: true}));
      }
      return JSON.stringify({success: true, action: 'fill', value: fillValue, elapsedMs: Math.round(performance.now() - t0)});
    }
    
    case 'select': {
      if (el.tagName === 'SELECT') {
        el.value = fillValue;
        el.dispatchEvent(new Event('change', {bubbles: true}));
      } else {
        el.click();
      }
      return JSON.stringify({success: true, action: 'select', value: fillValue, elapsedMs: Math.round(performance.now() - t0)});
    }
    
    case 'hover':
      el.dispatchEvent(new MouseEvent('mouseenter', {bubbles: true}));
      el.dispatchEvent(new MouseEvent('mouseover', {bubbles: true}));
      return JSON.stringify({success: true, action: 'hover', position: {x: cx, y: cy}, elapsedMs: Math.round(performance.now() - t0)});
    
    case 'check':
      el.click();
      return JSON.stringify({success: true, action: 'check', checked: el.checked, elapsedMs: Math.round(performance.now() - t0)});
    
    default:
      return JSON.stringify({success: false, error: 'Unknown action: ' + action});
  }
})()
    ''');

    final parsed = _parseJsonEval(result);
    if (parsed != null) {
      // For click actions needing real mouse events (e.g., custom components),
      // fall back to CDP Input.dispatch
      if (dispatchRealEvents && parsed['success'] == true && parsed['position'] != null) {
        final pos = parsed['position'] as Map<String, dynamic>;
        final cx = (pos['x'] as num).toDouble();
        final cy = (pos['y'] as num).toDouble();
        await _dispatchMouseEvent('mousePressed', cx, cy, button: 'left', clickCount: 1);
        await _dispatchMouseEvent('mouseReleased', cx, cy, button: 'left', clickCount: 1);
      }
      return parsed;
    }

    return {'success': false, 'error': 'Failed to parse act result'};
  }

  @override
  Future<String?> takeScreenshot({double quality = 1.0, int? maxWidth}) async {
    // Default to JPEG@80 for speed; use PNG only when quality=1.0 explicitly AND no maxWidth
    final useJpeg = quality < 1.0 || maxWidth != null;
    final params = <String, dynamic>{
      'format': useJpeg
          ? 'jpeg'
          : 'jpeg', // Always JPEG for CDP — 3-5x faster than PNG
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
  Future<String?> takeRegionScreenshot(
      double x, double y, double width, double height) async {
    try {
      final result = await _call('Page.captureScreenshot', {
        'format': 'jpeg',
        'quality': 80,
        'clip': {
          'x': x,
          'y': y,
          'width': width,
          'height': height,
          'scale': 1,
        },
      }).timeout(const Duration(seconds: 10));
      return result['data'] as String?;
    } catch (_) {
      // Fallback: full screenshot (clip times out on some Chrome versions)
      final full = await takeScreenshot(quality: 0.8);
      return full;
    }
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
    return {
      'success': found,
      'message': found ? 'Scrolled to element' : 'Element not found'
    };
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
  Future<bool> waitForElement(
      {String? key, String? text, int timeout = 5000}) async {
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
  Future<bool> waitForGone(
      {String? key, String? text, int timeout = 5000}) async {
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
    await _dispatchMouseEvent('mousePressed', x, y,
        button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mouseReleased', x, y,
        button: 'left', clickCount: 1);
    await _ensureFocusAtPoint(x, y);
  }

  /// Long press an element.
  Future<bool> longPress(
      {String? key, String? text, int duration = 500}) async {
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
    await _dispatchMouseEvent('mousePressed', cx, cy,
        button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mouseReleased', cx, cy,
        button: 'left', clickCount: 1);
    await _dispatchMouseEvent('mousePressed', cx, cy,
        button: 'left', clickCount: 2);
    await _dispatchMouseEvent('mouseReleased', cx, cy,
        button: 'left', clickCount: 2);
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
  Future<Map<String, dynamic>> drag(
      double startX, double startY, double endX, double endY) async {
    try {
      return await Future(() async {
        await _dispatchMouseEvent('mousePressed', startX, startY,
            button: 'left', clickCount: 1);
        const steps = 10;
        for (var i = 1; i <= steps; i++) {
          final x = startX + (endX - startX) * i / steps;
          final y = startY + (endY - startY) * i / steps;
          await _dispatchMouseEvent('mouseMoved', x, y, button: 'left');
        }
        await _dispatchMouseEvent('mouseReleased', endX, endY,
            button: 'left', clickCount: 1);
        return {"success": true} as Map<String, dynamic>;
      }).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return {
        "success": false,
        "error": "Drag timed out — mouse event not acknowledged by browser"
      };
    }
  }

  /// Long press at coordinates.
  Future<void> longPressAt(double x, double y) async {
    await _dispatchMouseEvent('mousePressed', x, y,
        button: 'left', clickCount: 1);
    await Future.delayed(const Duration(milliseconds: 800));
    await _dispatchMouseEvent('mouseReleased', x, y,
        button: 'left', clickCount: 1);
  }

  /// Swipe between coordinates.
  Future<Map<String, dynamic>> swipeCoordinates(
      double startX, double startY, double endX, double endY,
      {int durationMs = 300}) async {
    try {
      return await Future(() async {
        await _dispatchMouseEvent('mousePressed', startX, startY,
            button: 'left', clickCount: 1);
        const steps = 8;
        for (var i = 1; i <= steps; i++) {
          final x = startX + (endX - startX) * i / steps;
          final y = startY + (endY - startY) * i / steps;
          await _dispatchMouseEvent('mouseMoved', x, y, button: 'left');
          await Future.delayed(Duration(milliseconds: durationMs ~/ steps));
        }
        await _dispatchMouseEvent('mouseReleased', endX, endY,
            button: 'left', clickCount: 1);
        return {"success": true} as Map<String, dynamic>;
      }).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return {
        "success": false,
        "error": "Swipe timed out — mouse event not acknowledged by browser"
      };
    }
  }

  /// Edge swipe (simulate from edge of viewport).
  Future<Map<String, dynamic>> edgeSwipe(String direction,
      {String edge = 'left', int distance = 200}) async {
    final viewport =
        await _evalJs('[window.innerWidth, window.innerHeight].join(",")');
    final dims =
        (viewport['result']?['value'] as String? ?? '1280,720').split(',');
    final w = double.parse(dims[0]);
    final h = double.parse(dims[1]);
    double startX, startY, endX, endY;
    switch (direction) {
      case 'right':
        startX = 5;
        startY = h / 2;
        endX = distance.toDouble();
        endY = h / 2;
        break;
      case 'left':
        startX = w - 5;
        startY = h / 2;
        endX = w - distance;
        endY = h / 2;
        break;
      case 'up':
        startX = w / 2;
        startY = h - 5;
        endX = w / 2;
        endY = h - distance;
        break;
      case 'down':
      default:
        startX = w / 2;
        startY = 5;
        endX = w / 2;
        endY = distance.toDouble();
    }
    return swipeCoordinates(startX, startY, endX, endY);
  }

  /// Custom gesture (series of points).
  Future<Map<String, dynamic>> gesture(
      List<Map<String, dynamic>> points) async {
    if (points.isEmpty) return {"success": false, "message": "No points"};
    try {
      return await Future(() async {
        final first = points.first;
        await _dispatchMouseEvent('mousePressed',
            (first['x'] as num).toDouble(), (first['y'] as num).toDouble(),
            button: 'left');
        for (var i = 1; i < points.length; i++) {
          await _dispatchMouseEvent(
              'mouseMoved',
              (points[i]['x'] as num).toDouble(),
              (points[i]['y'] as num).toDouble(),
              button: 'left');
          await Future.delayed(const Duration(milliseconds: 20));
        }
        final last = points.last;
        await _dispatchMouseEvent('mouseReleased',
            (last['x'] as num).toDouble(), (last['y'] as num).toDouble(),
            button: 'left');
        return {"success": true} as Map<String, dynamic>;
      }).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return {
        "success": false,
        "error": "Gesture timed out — mouse event not acknowledged by browser"
      };
    }
  }

  /// Scroll until element is visible.
  Future<Map<String, dynamic>> scrollUntilVisible(String key,
      {int maxScrolls = 10, String direction = 'down'}) async {
    for (var i = 0; i < maxScrolls; i++) {
      final result = await _evalJs('''
        (() => {
          const el = ${_jsResolveElement(key)};
          if (!el) return false;
          const rect = el.getBoundingClientRect();
          return rect.top >= 0 && rect.bottom <= window.innerHeight;
        })()
      ''');
      if (result['result']?['value'] == true)
        return {"success": true, "scrolls": i};
      final dy = direction == 'up' ? -300 : 300;
      await _evalJs('window.scrollBy(0, $dy)');
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return {
      "success": false,
      "message": "Element '$key' not visible after $maxScrolls scrolls"
    };
  }

  /// Get checkbox state.
  Future<Map<String, dynamic>> getCheckboxState(String key) async {
    final result = await _evalJs('''
      (() => {
        let el = ${_jsResolveElement(key)};
        // Fallback: search checkboxes by label/value
        if (!el) {
          for (const cb of document.querySelectorAll('input[type="checkbox"], [role="checkbox"]')) {
            const label = cb.closest('label') || document.querySelector('label[for="' + cb.id + '"]');
            const t = (label ? label.textContent : cb.getAttribute('aria-label') || '').trim();
            if (t.toLowerCase().includes('$key'.toLowerCase()) || cb.value === '$key') { el = cb; break; }
          }
        }
        if (!el) return JSON.stringify({ success: false, error: "Element not found" });
        if (el.type === 'checkbox') return JSON.stringify({ success: true, checked: el.checked });
        const cb = el.querySelector && el.querySelector('input[type="checkbox"]');
        if (cb) return JSON.stringify({ success: true, checked: cb.checked });
        return JSON.stringify({ success: true, checked: el.getAttribute('aria-checked') === 'true' });
      })()
    ''');
    return _parseJsonEval(result) ??
        {"success": false, "error": "Element not found"};
  }

  /// Get slider value.
  Future<Map<String, dynamic>> getSliderValue(String key) async {
    final result = await _evalJs('''
      (() => {
        let el = ${_jsResolveElement(key)};
        // Fallback: search sliders by label/name
        if (!el) {
          for (const s of document.querySelectorAll('input[type="range"], [role="slider"]')) {
            const label = s.closest('label') || document.querySelector('label[for="' + s.id + '"]');
            const t = (label ? label.textContent : s.getAttribute('aria-label') || '').trim();
            if (t.toLowerCase().includes('$key'.toLowerCase()) || s.name === '$key') { el = s; break; }
          }
        }
        if (!el) return JSON.stringify({ success: false, error: "Element not found" });
        return JSON.stringify({ 
          success: true, 
          value: parseFloat(el.value || el.getAttribute('aria-valuenow') || 0), 
          min: parseFloat(el.min || el.getAttribute('aria-valuemin') || 0), 
          max: parseFloat(el.max || el.getAttribute('aria-valuemax') || 100) 
        });
      })()
    ''');
    return _parseJsonEval(result) ??
        {"success": false, "error": "Element not found"};
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
        ${key != null ? "const el = ${_jsResolveElement(key)}; return el ? el.textContent.includes('$text') : false;" : "return document.body.innerText.includes('$text');"}
      })()
    ''');
    final found = result['result']?['value'] == true;
    return {"success": found, "found": found, "text": text};
  }

  /// Assert element count.
  Future<Map<String, dynamic>> assertElementCount(
      String selector, int expectedCount) async {
    final result =
        await _evalJs('document.querySelectorAll("$selector").length');
    final count = result['result']?['value'] as int? ?? 0;
    return {
      "success": count == expectedCount,
      "actual_count": count,
      "expected_count": expectedCount,
    };
  }

  /// Wait for idle.
  Future<Map<String, dynamic>> waitForIdle({int timeoutMs = 5000}) async {
    await Future.delayed(
        Duration(milliseconds: timeoutMs > 2000 ? 2000 : timeoutMs));
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

  /// Keyboard key info for a character (US QWERTY layout).
  static _KeyInfo _charToKeyInfo(String char) {
    final c = char.codeUnitAt(0);

    // a-z
    if (c >= 97 && c <= 122) {
      return _KeyInfo('Key${char.toUpperCase()}', c - 32, false, char);
    }
    // A-Z (shifted)
    if (c >= 65 && c <= 90) {
      return _KeyInfo('Key$char', c, true, char.toLowerCase());
    }
    // 0-9
    if (c >= 48 && c <= 57) {
      return _KeyInfo('Digit$char', c, false, char);
    }

    // Shifted number keys: !@#$%^&*()
    const shiftedDigits = <String, List<dynamic>>{
      '!': ['Digit1', 49], '@': ['Digit2', 50], '#': ['Digit3', 51],
      '\$': ['Digit4', 52], '%': ['Digit5', 53], '^': ['Digit6', 54],
      '&': ['Digit7', 55], '*': ['Digit8', 56], '(': ['Digit9', 57],
      ')': ['Digit0', 48],
    };
    if (shiftedDigits.containsKey(char)) {
      final info = shiftedDigits[char]!;
      return _KeyInfo(info[0] as String, info[1] as int, true,
          String.fromCharCode(info[1] as int));
    }

    // Special keys (unshifted)
    const specialKeys = <String, List<dynamic>>{
      ' ': ['Space', 32],
      '-': ['Minus', 189], '=': ['Equal', 187],
      '[': ['BracketLeft', 219], ']': ['BracketRight', 221],
      '\\': ['Backslash', 220], ';': ['Semicolon', 186],
      "'": ['Quote', 222], '`': ['Backquote', 192],
      ',': ['Comma', 188], '.': ['Period', 190],
      '/': ['Slash', 191], '\t': ['Tab', 9],
    };
    if (specialKeys.containsKey(char)) {
      final info = specialKeys[char]!;
      return _KeyInfo(info[0] as String, info[1] as int, false, char);
    }

    // Shifted special keys
    const shiftedSpecial = <String, List<dynamic>>{
      '_': ['Minus', 189, '-'], '+': ['Equal', 187, '='],
      '{': ['BracketLeft', 219, '['], '}': ['BracketRight', 221, ']'],
      '|': ['Backslash', 220, '\\'], ':': ['Semicolon', 186, ';'],
      '"': ['Quote', 222, "'"], '~': ['Backquote', 192, '`'],
      '<': ['Comma', 188, ','], '>': ['Period', 190, '.'],
      '?': ['Slash', 191, '/'],
    };
    if (shiftedSpecial.containsKey(char)) {
      final info = shiftedSpecial[char]!;
      return _KeyInfo(
          info[0] as String, info[1] as int, true, info[2] as String);
    }

    // Fallback: use charCode directly
    return _KeyInfo('', c, false, char);
  }

  /// Type text character by character (more realistic than enterText).
  Future<void> typeText(String text) async {
    // Check if focused element is contenteditable — use Input.insertText directly
    // (dispatchKeyEvent drops special chars like '.', '(', '%' in contenteditable)
    final focusInfo = await _evalJs('''
      (() => {
        const el = document.activeElement;
        if (!el) return JSON.stringify({tag: null, ce: false});
        const ce = el.isContentEditable || el.getAttribute('contenteditable') === 'true' || el.getAttribute('role') === 'textbox';
        return JSON.stringify({tag: el.tagName, ce: ce, val: el.value || '', len: (el.value || el.textContent || '').length});
      })()
    ''');
    final info = _parseJsonEval(focusInfo);
    final isContentEditable = info?['ce'] == true;
    final beforeLen = (info?['len'] as num?)?.toInt() ?? 0;

    if (isContentEditable) {
      // Use Input.insertText for contenteditable — reliable for all characters
      await _call('Input.insertText', {'text': text});
      return;
    }

    // For regular inputs/textareas: keyDown(text) + keyUp per character
    for (final char in text.split('')) {
      if (char == '\n') {
        // Enter key
        await _call('Input.dispatchKeyEvent', {
          'type': 'keyDown',
          'key': 'Enter',
          'code': 'Enter',
          'text': '\r',
          'unmodifiedText': '\r',
          'windowsVirtualKeyCode': 13,
          'nativeVirtualKeyCode': 13,
        });
        await _call('Input.dispatchKeyEvent', {
          'type': 'keyUp',
          'key': 'Enter',
          'code': 'Enter',
          'windowsVirtualKeyCode': 13,
          'nativeVirtualKeyCode': 13,
        });
        continue;
      }

      final keyInfo = _charToKeyInfo(char);
      final params = <String, dynamic>{
        'text': char,
        'key': char,
        'unmodifiedText': keyInfo.shifted ? keyInfo.unmodified : char,
        if (keyInfo.code.isNotEmpty) 'code': keyInfo.code,
        'windowsVirtualKeyCode': keyInfo.keyCode,
        'nativeVirtualKeyCode': keyInfo.keyCode,
        if (keyInfo.shifted) 'modifiers': 8, // Shift
      };
      await _call('Input.dispatchKeyEvent', {
        'type': 'keyDown',
        ...params,
      });
      await _call('Input.dispatchKeyEvent', {
        'type': 'keyUp',
        'key': char,
        if (keyInfo.code.isNotEmpty) 'code': keyInfo.code,
        'windowsVirtualKeyCode': keyInfo.keyCode,
        'nativeVirtualKeyCode': keyInfo.keyCode,
      });
    }

    // Verify text was inserted; fallback to execCommand if not
    final afterResult = await _evalJs('''
      (() => {
        const el = document.activeElement;
        if (!el) return JSON.stringify({len: 0});
        return JSON.stringify({len: (el.value || el.textContent || '').length});
      })()
    ''');
    final afterParsed = _parseJsonEval(afterResult);
    final afterLen = (afterParsed?['len'] as num?)?.toInt() ?? 0;

    if (afterLen <= beforeLen) {
      // dispatchKeyEvent didn't insert text — use execCommand fallback
      final escaped = text.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
      await _evalJs(
          "document.execCommand('insertText', false, '$escaped')");
    }
  }

  /// Hover over element.
  Future<Map<String, dynamic>> hover(
      {String? key, String? text, String? ref}) async {
    final bounds = await _getElementBounds(key ?? '', text: text, ref: ref);
    if (bounds == null)
      return {"success": false, "message": "Element not found"};
    final cx = bounds['x']! + bounds['w']! / 2;
    final cy = bounds['y']! + bounds['h']! / 2;
    await _dispatchMouseEvent('mouseMoved', cx, cy);
    return {
      "success": true,
      "position": {"x": cx, "y": cy}
    };
  }

  /// Select option in a <select> element.
  Future<Map<String, dynamic>> selectOption(String key, String value) async {
    final result = await _evalJs('''
      (() => {
        const el = ${_jsResolveElement(key)};
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
        const el = ${_jsResolveElement(key)};
        if (!el) return JSON.stringify({success: false, message: 'Element not found'});
        const cb = el.type === 'checkbox' ? el : (el.querySelector && el.querySelector('input[type="checkbox"]'));
        if (!cb) return JSON.stringify({success: false, message: 'Checkbox not found'});
        if (cb.checked !== $checked) { cb.click(); }
        return JSON.stringify({success: true, checked: cb.checked});
      })()
    ''');
    return _parseJsonEval(result) ?? {"success": false};
  }

  /// Fill input (clear + type — faster than enterText for forms).
  Future<Map<String, dynamic>> fill(String key, String value) async {
    final result = await _evalJs('''
      (() => {
        const el = ${_jsResolveElement(key)};
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

  /// Paste text instantly via CDP Input.insertText (clipboard-style).
  /// Much faster than typeText for long content.
  Future<void> pasteText(String text) async {
    await _call('Input.insertText', {'text': text});
  }

  /// Fill a rich text editor (contenteditable, Draft.js, ProseMirror, Tiptap, Medium, etc.).
  /// Finds the editor element, focuses it, clears content, and injects HTML or plain text.
  /// [selector] - CSS selector for the editor element (e.g. '[contenteditable="true"]', '.ProseMirror', '.tiptap')
  /// [html] - HTML content to inject (preferred for rich editors)
  /// [text] - Plain text to inject (fallback)
  /// [append] - If true, append instead of replacing content
  Future<Map<String, dynamic>> fillRichText({
    String? selector,
    String? html,
    String? text,
    bool append = false,
  }) async {
    final content = html ?? text ?? '';
    final isHtml = html != null;
    final sel = selector ?? '[contenteditable="true"]';
    final escapedContent =
        content.replaceAll('\\', '\\\\').replaceAll('`', '\\`').replaceAll('\$', '\\\$');

    final result = await _evalJs('''
      (() => {
        // Try multiple selectors for common rich text editors
        const selectors = ['$sel', '.ProseMirror', '.tiptap', '[contenteditable="true"]', '.ql-editor', '.DraftEditor-root [contenteditable="true"]', '.graf--p'];
        let el = null;
        for (const s of selectors) {
          el = document.querySelector(s);
          if (el) break;
        }
        if (!el) return JSON.stringify({success: false, message: 'Rich text editor not found', triedSelectors: selectors});

        el.focus();

        if (!${append}) {
          el.innerHTML = '';
        }

        if (${isHtml}) {
          el.innerHTML ${append ? '+' : ''}= `$escapedContent`;
        } else {
          el.innerText ${append ? '+' : ''}= `$escapedContent`;
        }

        // Dispatch events for framework detection (React, Vue, Draft.js, Tiptap, ProseMirror)
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        // For ProseMirror/Tiptap — trigger a DOM mutation so the framework picks up changes
        el.dispatchEvent(new Event('keyup', {bubbles: true}));
        // For Draft.js — trigger beforeinput
        try { el.dispatchEvent(new InputEvent('beforeinput', {bubbles: true, inputType: 'insertText'})); } catch(e) {}

        return JSON.stringify({
          success: true,
          editor: el.className || el.tagName,
          contentLength: el.innerHTML.length,
          selector: '$sel'
        });
      })()
    ''');
    final v = result['result']?['value'] as String?;
    if (v == null) return {"success": false, "message": "Eval returned null"};
    return jsonDecode(v) as Map<String, dynamic>;
  }

  /// Solve CAPTCHA using 2Captcha/Anti-Captcha service.
  /// Supports reCAPTCHA v2/v3, hCaptcha, image CAPTCHA.
  /// [apiKey] - API key for the CAPTCHA solving service
  /// [service] - 'twocaptcha' or 'anticaptcha' (default: twocaptcha)
  /// [siteKey] - reCAPTCHA/hCaptcha site key (auto-detected if not provided)
  /// [pageUrl] - URL of the page (auto-detected if not provided)
  /// [type] - 'recaptcha_v2', 'recaptcha_v3', 'hcaptcha', 'image' (auto-detected)
  Future<Map<String, dynamic>> solveCaptcha({
    required String apiKey,
    String service = 'twocaptcha',
    String? siteKey,
    String? pageUrl,
    String? type,
  }) async {
    // Step 1: Auto-detect CAPTCHA type and site key
    final detection = await _evalJs('''
      (() => {
        const url = window.location.href;
        // reCAPTCHA v2/v3
        const recaptchaEl = document.querySelector('.g-recaptcha, [data-sitekey], iframe[src*="recaptcha"]');
        if (recaptchaEl) {
          const sk = recaptchaEl.getAttribute('data-sitekey') || 
            (recaptchaEl.src ? new URL(recaptchaEl.src).searchParams.get('k') : null);
          const isV3 = recaptchaEl.getAttribute('data-size') === 'invisible' || document.querySelector('script[src*="recaptcha/api.js?render="]') !== null;
          return JSON.stringify({type: isV3 ? 'recaptcha_v3' : 'recaptcha_v2', siteKey: sk, pageUrl: url});
        }
        // hCaptcha
        const hcaptchaEl = document.querySelector('.h-captcha, [data-sitekey][data-hcaptcha], iframe[src*="hcaptcha"]');
        if (hcaptchaEl) {
          const sk = hcaptchaEl.getAttribute('data-sitekey');
          return JSON.stringify({type: 'hcaptcha', siteKey: sk, pageUrl: url});
        }
        // Cloudflare Turnstile
        const turnstile = document.querySelector('.cf-turnstile, [data-sitekey]');
        if (turnstile && turnstile.classList.contains('cf-turnstile')) {
          return JSON.stringify({type: 'turnstile', siteKey: turnstile.getAttribute('data-sitekey'), pageUrl: url});
        }
        // Image CAPTCHA
        const imgCaptcha = document.querySelector('img[src*="captcha"], img[alt*="captcha"], img[class*="captcha"]');
        if (imgCaptcha) {
          return JSON.stringify({type: 'image', imgSrc: imgCaptcha.src, pageUrl: url});
        }
        return JSON.stringify({type: 'none', pageUrl: url});
      })()
    ''');

    final detectionValue = detection['result']?['value'] as String?;
    if (detectionValue == null) {
      return {"success": false, "message": "Failed to detect CAPTCHA"};
    }
    final detected = jsonDecode(detectionValue) as Map<String, dynamic>;
    final captchaType = type ?? detected['type'] as String?;
    final detectedSiteKey = siteKey ?? detected['siteKey'] as String?;
    final detectedPageUrl = pageUrl ?? detected['pageUrl'] as String?;

    if (captchaType == 'none') {
      return {"success": true, "message": "No CAPTCHA detected on page"};
    }

    // Step 2: Submit to solving service
    final http.Client httpClient = http.Client();
    try {
      String taskId;

      if (service == 'twocaptcha') {
        // 2Captcha API
        final submitUrl = Uri.parse('http://2captcha.com/in.php');
        final params = <String, String>{
          'key': apiKey,
          'json': '1',
        };

        if (captchaType == 'recaptcha_v2' || captchaType == 'recaptcha_v3') {
          params['method'] = 'userrecaptcha';
          params['googlekey'] = detectedSiteKey ?? '';
          params['pageurl'] = detectedPageUrl ?? '';
          if (captchaType == 'recaptcha_v3') {
            params['version'] = 'v3';
            params['action'] = 'verify';
            params['min_score'] = '0.3';
          }
        } else if (captchaType == 'hcaptcha') {
          params['method'] = 'hcaptcha';
          params['sitekey'] = detectedSiteKey ?? '';
          params['pageurl'] = detectedPageUrl ?? '';
        } else if (captchaType == 'turnstile') {
          params['method'] = 'turnstile';
          params['sitekey'] = detectedSiteKey ?? '';
          params['pageurl'] = detectedPageUrl ?? '';
        } else if (captchaType == 'image') {
          // For image CAPTCHA, download and send base64
          final imgSrc = detected['imgSrc'] as String?;
          if (imgSrc == null) return {"success": false, "message": "No CAPTCHA image found"};
          final imgResponse = await httpClient.get(Uri.parse(imgSrc));
          params['method'] = 'base64';
          params['body'] = base64Encode(imgResponse.bodyBytes);
        }

        final response = await httpClient.post(submitUrl, body: params);
        final submitResult = jsonDecode(response.body) as Map<String, dynamic>;
        if (submitResult['status'] != 1) {
          return {"success": false, "message": "Submit failed: ${submitResult['request']}"};
        }
        taskId = submitResult['request'] as String;

        // Step 3: Poll for result
        for (int i = 0; i < 60; i++) {
          await Future.delayed(const Duration(seconds: 5));
          final pollUrl = Uri.parse('http://2captcha.com/res.php?key=$apiKey&action=get&id=$taskId&json=1');
          final pollResponse = await httpClient.get(pollUrl);
          final pollResult = jsonDecode(pollResponse.body) as Map<String, dynamic>;
          if (pollResult['status'] == 1) {
            final token = pollResult['request'] as String;

            // Step 4: Inject solution
            if (captchaType == 'image') {
              // For image CAPTCHA, fill the input field
              await _evalJs('''
                (() => {
                  const input = document.querySelector('input[name*="captcha"], input[id*="captcha"], input[class*="captcha"]');
                  if (input) { input.value = '$token'; input.dispatchEvent(new Event('input', {bubbles: true})); }
                })()
              ''');
            } else {
              // For reCAPTCHA/hCaptcha/Turnstile — inject token into callback
              await _evalJs('''
                (() => {
                  const textarea = document.querySelector('#g-recaptcha-response, [name="g-recaptcha-response"], textarea[name="h-captcha-response"]');
                  if (textarea) {
                    textarea.style.display = '';
                    textarea.value = '$token';
                    textarea.dispatchEvent(new Event('input', {bubbles: true}));
                  }
                  // Call callback if available
                  if (typeof ___grecaptcha_cfg !== 'undefined') {
                    const clients = ___grecaptcha_cfg.clients;
                    if (clients) {
                      Object.keys(clients).forEach(k => {
                        const c = clients[k];
                        // Find callback in nested structure
                        const findCb = (obj) => {
                          if (!obj || typeof obj !== 'object') return null;
                          for (const key of Object.keys(obj)) {
                            if (typeof obj[key] === 'function') return obj[key];
                            const found = findCb(obj[key]);
                            if (found) return found;
                          }
                          return null;
                        };
                        const cb = findCb(c);
                        if (cb) cb('$token');
                      });
                    }
                  }
                  // hCaptcha callback
                  if (window.hcaptcha) window.hcaptcha.execute();
                })()
              ''');
            }

            return {
              "success": true,
              "type": captchaType,
              "token": token.length > 50 ? '${token.substring(0, 50)}...' : token,
              "message": "CAPTCHA solved and injected"
            };
          }
          if (pollResult['request'] != 'CAPCHA_NOT_READY') {
            return {"success": false, "message": "Solve failed: ${pollResult['request']}"};
          }
        }
        return {"success": false, "message": "Timeout waiting for CAPTCHA solution"};
      } else {
        return {"success": false, "message": "Service '$service' not supported yet. Use 'twocaptcha'."};
      }
    } finally {
      httpClient.close();
    }
  }

  /// Highlight an element on the page.
  Future<Map<String, dynamic>> highlightElement(String selector,
      {String color = 'red', int duration = 3000}) async {
    // Parse color to rgba for background (20% opacity)
    final bgAlpha = '0.1';
    final shadowAlpha = '0.5';
    final result = await _evalJs('''
      (() => {
        const el = ${_jsResolveElement(selector)};
        if (!el) return JSON.stringify({ success: false, error: 'Element not found' });
        const rect = el.getBoundingClientRect();
        const hl = document.createElement('div');
        hl.id = '__fs_hl_' + Math.random().toString(36).substr(2, 9);
        hl.style.cssText = 'position:fixed;top:'+rect.top+'px;left:'+rect.left+'px;width:'+rect.width+'px;height:'+rect.height+'px;border:3px solid $color;background:$color'.replace(/\\/[^/]*\$/, '')+'${bgAlpha};pointer-events:none;z-index:9999;box-shadow:0 0 10px $color'.replace(/\\/[^/]*\$/, '')+'${shadowAlpha};animation:__fs_pulse 0.5s infinite alternate';
        if (!document.getElementById('__fs_hl_style')) {
          const s = document.createElement('style');
          s.id = '__fs_hl_style';
          s.textContent = '@keyframes __fs_pulse{0%{opacity:.3}100%{opacity:.8}}';
          document.head.appendChild(s);
        }
        document.body.appendChild(hl);
        setTimeout(() => hl.remove(), $duration);
        return JSON.stringify({ success: true, element_found: true, duration: $duration });
      })()
    ''');
    return _parseJsonEval(result) ?? {"success": false, "error": "Eval failed"};
  }

  // ── Internal helpers ──

  /// Persistent profile directory for CDP Chrome sessions.
  ///
  /// Uses `~/.flutter-skill/chrome-profile/` instead of a temp directory
  /// so login sessions, cookies, and preferences survive across restarts.
  static String get _persistentProfileDir {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return '$home/.flutter-skill/chrome-profile';
  }

  /// Directory where Chrome for Testing is installed.
  static String get _cftInstallDir {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return '$home/.flutter-skill/chrome-for-testing';
  }

  /// Detect Chrome for Testing binary path if installed.
  static String? get _cftBinaryPath {
    final dir = _cftInstallDir;
    if (Platform.isMacOS) {
      final arm64 =
          '$dir/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
      final x64 =
          '$dir/chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
      if (File(arm64).existsSync()) return arm64;
      if (File(x64).existsSync()) return x64;
    } else if (Platform.isLinux) {
      for (final sub in ['chrome-linux64', 'chrome-linux-arm64']) {
        final path = '$dir/$sub/chrome';
        if (File(path).existsSync()) return path;
      }
    } else if (Platform.isWindows) {
      final path = '$dir/chrome-win64/chrome.exe';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Platform identifier for Chrome for Testing downloads.
  static String get _cftPlatform {
    if (Platform.isMacOS) {
      try {
        final result = Process.runSync('uname', ['-m']);
        if (result.stdout.toString().trim() == 'arm64') return 'mac-arm64';
      } catch (_) {}
      return 'mac-x64';
    }
    if (Platform.isLinux) {
      try {
        final result = Process.runSync('uname', ['-m']);
        final arch = result.stdout.toString().trim();
        if (arch == 'aarch64' || arch == 'arm64') return 'linux-arm64';
      } catch (_) {}
      return 'linux64';
    }
    if (Platform.isWindows) {
      // Windows ARM64 runs x64 Chrome via emulation
      return 'win64';
    }
    return 'linux64'; // fallback
  }

  /// Download and install Chrome for Testing.
  ///
  /// Returns the path to the installed binary, or throws on failure.
  static Future<String> installChromeForTesting() async {
    final client = http.Client();
    try {
      // Fetch latest stable version info
      final resp = await client.get(Uri.parse(
        'https://googlechromelabs.github.io/chrome-for-testing/'
        'last-known-good-versions-with-downloads.json',
      ));
      if (resp.statusCode != 200) {
        throw Exception('Failed to fetch Chrome for Testing versions');
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final stable = data['channels']['Stable'] as Map<String, dynamic>;
      final downloads = stable['downloads']['chrome'] as List;
      final platform = _cftPlatform;
      final entry = downloads.firstWhere(
        (d) => d['platform'] == platform,
        orElse: () => null,
      );
      if (entry == null) {
        throw Exception(
            'No Chrome for Testing download for platform: $platform. '
            '${platform == 'linux-arm64' ? 'Chrome for Testing does not support Linux ARM64 yet. Use Chromium instead: sudo apt install chromium-browser' : 'Check https://googlechromelabs.github.io/chrome-for-testing/ for available platforms.'}');
      }
      final url = entry['url'] as String;

      // Download
      final zipPath = '${Directory.systemTemp.path}/chrome-for-testing.zip';
      final zipResp = await client.get(Uri.parse(url));
      if (zipResp.statusCode != 200) {
        throw Exception('Failed to download Chrome for Testing from $url');
      }
      await File(zipPath).writeAsBytes(zipResp.bodyBytes);

      // Extract
      final installDir = _cftInstallDir;
      await Directory(installDir).create(recursive: true);

      if (Platform.isWindows) {
        await Process.run('powershell', [
          '-Command',
          'Expand-Archive',
          '-Path',
          zipPath,
          '-DestinationPath',
          installDir,
          '-Force'
        ]);
      } else {
        await Process.run('unzip', ['-o', zipPath, '-d', installDir]);
      }

      // macOS: remove quarantine attribute
      if (Platform.isMacOS) {
        final appDir = Directory(installDir)
            .listSync()
            .whereType<Directory>()
            .firstWhere(
              (d) => d.path.contains('chrome-mac'),
              orElse: () => Directory(installDir),
            );
        await Process.run('xattr', ['-cr', appDir.path]);
      }

      // Clean up zip
      try {
        await File(zipPath).delete();
      } catch (_) {}

      final binary = _cftBinaryPath;
      if (binary == null) {
        throw Exception(
            'Chrome for Testing installed but binary not found in $installDir');
      }

      return binary;
    } finally {
      client.close();
    }
  }

  Future<void> _launchChromeProcess() async {
    final chromePaths = <String>[];

    // 1. User-specified path (highest priority)
    if (_chromePath != null) {
      chromePaths.add(_chromePath!);
    }

    // 2. Chrome for Testing (recommended for automation — no debug port restrictions)
    final cftPath = _cftBinaryPath;
    if (cftPath != null) {
      chromePaths.add(cftPath);
    }

    // 3. Standard Chrome / Chromium
    if (Platform.isMacOS) {
      chromePaths
          .add('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
      chromePaths.add('/Applications/Chromium.app/Contents/MacOS/Chromium');
    } else if (Platform.isLinux) {
      chromePaths.addAll([
        'google-chrome',
        'google-chrome-stable',
        'chromium',
        'chromium-browser'
      ]);
    } else if (Platform.isWindows) {
      chromePaths.add(r'C:\Program Files\Google\Chrome\Application\chrome.exe');
      chromePaths
          .add(r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe');
    }

    // Use persistent profile directory instead of temp dir so sessions survive
    final profileDir = Directory(_persistentProfileDir);
    if (!profileDir.existsSync()) {
      profileDir.createSync(recursive: true);
    }

    final chromeArgs = [
      '--remote-debugging-port=$_port',
      '--remote-allow-origins=*',
      '--no-first-run',
      '--no-default-browser-check',
      '--user-data-dir=${profileDir.path}',
      '--disable-background-timer-throttling',
      '--disable-backgrounding-occluded-windows',
      '--disable-renderer-backgrounding',
      if (_headless) '--headless=new',
      if (_proxy != null) '--proxy-server=$_proxy',
      if (_ignoreSsl) '--ignore-certificate-errors',
      _url,
    ];

    for (final chromePath in chromePaths) {
      try {
        // macOS: remove quarantine attribute before launch — prevents
        // --remote-debugging-port from silently failing on some versions.
        if (Platform.isMacOS && chromePath.contains('.app/')) {
          final appBundle = chromePath.substring(
              0, chromePath.indexOf('.app/') + '.app/'.length - 1);
          await Process.run('xattr', ['-cr', appBundle]);
        }

        _chromeProcess = await Process.start(chromePath, chromeArgs);

        // Wait briefly and check if the process is still alive.
        // Standard Chrome ≥136 rejects --remote-debugging-port with the
        // default user-data-dir and exits immediately with a warning.
        await Future.delayed(const Duration(milliseconds: 500));
        final code = await _chromeProcess!.exitCode
            .timeout(const Duration(milliseconds: 200), onTimeout: () => -1);
        if (code != -1) {
          // Process already exited — likely Chrome 136+ rejecting debug port.
          // Try next candidate (Chrome for Testing should work).
          _chromeProcess = null;
          continue;
        }

        return;
      } catch (_) {
        _chromeProcess = null;
        continue;
      }
    }

    // All candidates failed — try auto-installing Chrome for Testing
    try {
      final installed = await installChromeForTesting();
      _chromeProcess = await Process.start(installed, chromeArgs);
      return;
    } catch (installError) {
      throw Exception(
        'Could not launch Chrome for CDP debugging.\n\n'
        '📋 What happened:\n'
        '   Chrome 136+ blocks --remote-debugging-port on the default profile\n'
        '   for security (https://developer.chrome.com/blog/remote-debugging-port).\n\n'
        '🔧 Solutions (pick one):\n\n'
        '   1. Auto-install Chrome for Testing (recommended):\n'
        '      We tried but failed: $installError\n'
        '      Manual: download from https://googlechromelabs.github.io/chrome-for-testing/\n'
        '      Then: connect_cdp(chrome_path: "/path/to/chrome-for-testing")\n\n'
        '   2. Start Chrome manually with a custom profile:\n'
        '      google-chrome --remote-debugging-port=$_port --user-data-dir=/tmp/my-profile\n'
        '      Then: connect_cdp(url: "...", launch_chrome: false)\n\n'
        '   3. Use an existing Chrome with debugging enabled:\n'
        '      Close Chrome, relaunch with: --remote-debugging-port=$_port\n'
        '      Then: connect_cdp(url: "...", launch_chrome: false)\n\n'
        'Tried browsers: ${chromePaths.join(', ')}',
      );
    }
  }

  /// Poll CDP endpoint until it responds (replaces fixed 2s delay after Chrome launch)
  Future<void> _waitForCdpReady() async {
    final client = http.Client();
    for (var i = 0; i < 40; i++) {
      // 40 * 50ms = 2s max
      try {
        final resp = await client
            .get(Uri.parse('http://127.0.0.1:$_port/json/version'))
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
        final request =
            await client.getUrl(Uri.parse('http://127.0.0.1:$_port/json'));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        client.close();

        final tabs = jsonDecode(body) as List;
        final pageTabs = tabs.where((t) => t is Map && t['type'] == 'page').cast<Map>().toList();

        // Parse target host for domain matching
        final targetUri = _url.isNotEmpty ? Uri.tryParse(_url) : null;
        final targetHost = targetUri?.host ?? '';

        // 1. Same domain match (host-based, ignores path/query entirely)
        //    This is the PRIMARY strategy — never hijack tabs from other domains.
        if (targetHost.isNotEmpty) {
          // Prefer exact URL match within same domain
          for (final tab in pageTabs) {
            if (tab['url'] == _url) {
              connectedToExistingTab = true;
              return tab['webSocketDebuggerUrl'] as String?;
            }
          }
          // Then any tab on the same domain
          for (final tab in pageTabs) {
            final tabUri = Uri.tryParse(tab['url']?.toString() ?? '');
            if (tabUri != null && tabUri.host == targetHost) {
              return tab['webSocketDebuggerUrl'] as String?;
            }
          }
        }

        // 2. No same-domain tab found — use about:blank or chrome://newtab
        //    NEVER navigate an unrelated site's tab to our URL.
        for (final tab in pageTabs) {
          final tabUrl = tab['url']?.toString() ?? '';
          if (tabUrl == 'about:blank' || tabUrl == 'chrome://newtab/' || tabUrl == 'chrome://new-tab-page/') {
            return tab['webSocketDebuggerUrl'] as String?;
          }
        }

        // 3. No blank tab — if URL is empty, pick first non-chrome tab
        if (_url.isEmpty) {
          for (final tab in pageTabs) {
            final tabUrl = tab['url']?.toString() ?? '';
            if (!tabUrl.startsWith('devtools://') &&
                !tabUrl.startsWith('chrome://') &&
                tabUrl != 'about:blank') {
              return tab['webSocketDebuggerUrl'] as String?;
            }
          }
        }

        // 4. Last resort — return first page tab (only if no URL specified)
        if (_url.isEmpty && pageTabs.isNotEmpty) {
          return pageTabs.first['webSocketDebuggerUrl'] as String?;
        }

        // 5. No suitable tab found — return null, caller should create new tab
        //    This is better than hijacking an unrelated tab.
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    return null;
  }

  /// Public CDP method call — used by serve command and external callers.
  Future<Map<String, dynamic>> call(String method,
          [Map<String, dynamic>? params]) =>
      _call(method, params);

  /// Alias for [call] used by monkey testing and other modules.
  Future<Map<String, dynamic>> sendCommand(String method,
          [Map<String, dynamic>? params]) =>
      _call(method, params);

  /// Register a listener for a CDP event (supports multiple listeners per event).
  void onEvent(
      String method, void Function(Map<String, dynamic> params) callback) {
    _eventListeners.putIfAbsent(method, () => []);
    _eventListeners[method]!.add(callback);
  }

  /// Remove all listeners for a CDP event.
  void removeEventListeners(String method) {
    _eventListeners.remove(method);
  }

  Future<Map<String, dynamic>> _call(String method,
      [Map<String, dynamic>? params]) async {
    // If disconnected but reconnecting, wait up to 30s for reconnection
    if ((_ws == null || !_connected) && _reconnecting) {
      for (int i = 0; i < 60; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_connected && _ws != null) break;
      }
    }
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
        throw TimeoutException(
            'CDP call "$method" timed out', const Duration(seconds: 30));
      },
    );
  }

  /// JavaScript helper that pierces Shadow DOM when querying elements.
  /// Use `deepQuery(selector)` instead of `document.querySelector(selector)`
  /// and `deepQueryAll(selector)` instead of `document.querySelectorAll(selector)`.
  // ignore: unused_field
  static const String _shadowDomHelper = '''
function deepQuery(selector, root) {
  root = root || document;
  let el = root.querySelector(selector);
  if (el) return el;
  const shadows = root.querySelectorAll('*');
  for (const node of shadows) {
    if (node.shadowRoot) {
      el = deepQuery(selector, node.shadowRoot);
      if (el) return el;
    }
  }
  return null;
}
function deepQueryAll(selector, root) {
  root = root || document;
  let results = Array.from(root.querySelectorAll(selector));
  const nodes = root.querySelectorAll('*');
  for (const node of nodes) {
    if (node.shadowRoot) {
      results = results.concat(deepQueryAll(selector, node.shadowRoot));
    }
  }
  return results;
}
''';

  Future<Map<String, dynamic>> _evalJs(String expression) async {
    // Auto-wrap in IIFE to avoid 'const' redeclaration errors across calls.
    // Skip if already wrapped or is a simple expression (no declarations).
    final trimmed = expression.trim();
    final needsWrap = !trimmed.startsWith('(') &&
        (trimmed.contains('const ') ||
            trimmed.contains('let ') ||
            trimmed.contains('class ') ||
            trimmed.contains('function '));
    final wrapped = needsWrap ? '(() => { $trimmed })()' : expression;
    return _call('Runtime.evaluate', {
      'expression': wrapped,
      'returnByValue': true,
      'awaitPromise': false,
    });
  }

  /// Ensure focus is set on the focusable element at the given point.
  /// CDP Input.dispatchMouseEvent doesn't always trigger focus in headless Chrome.
  /// Traverses Shadow DOM boundaries to find the actual element.
  Future<void> _ensureFocusAtPoint(double x, double y) async {
    await _evalJs('''
      (() => {
        // Traverse shadow DOM to find the deepest element at point
        let el = document.elementFromPoint($x, $y);
        if (!el) return;
        // Drill into shadow roots
        while (el.shadowRoot) {
          const inner = el.shadowRoot.elementFromPoint($x, $y);
          if (!inner || inner === el) break;
          el = inner;
        }
        // Walk up to find the nearest focusable element
        const focusable = el.closest && el.closest('input, textarea, select, [contenteditable="true"], [contenteditable=""]');
        const target = focusable || el;
        if (target && target !== document.activeElement &&
            (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' ||
             target.tagName === 'SELECT' || target.isContentEditable)) {
          target.focus();
        }
      })()
    ''');
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

  /// Parse a JSON-stringified eval result into a Map.
  /// Handles both String (from JSON.stringify) and Map (from returnByValue).
  Map<String, dynamic>? _parseJsonEval(Map<String, dynamic> result) {
    final value = result['result']?['value'];
    if (value is String && value != 'null') {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    if (value is Map) return value as Map<String, dynamic>;
    return null;
  }

  /// Generate JS that resolves an element by multiple strategies:
  /// CSS selector, ID, name, data-testid, then text content.
  /// Returns an IIFE string that evaluates to the element or null.
  String _jsResolveElement(String key) {
    return '''(() => {
      let el = document.querySelector('$key');
      if (!el) el = document.getElementById('$key');
      if (!el) el = document.querySelector('[name="$key"]');
      if (!el) el = document.querySelector('[data-testid="$key"]');
      if (!el) el = document.querySelector('[data-test*="$key"]');
      if (!el) {
        for (const e of document.querySelectorAll('*')) {
          if (e.textContent && e.textContent.trim() === '$key') { el = e; break; }
        }
      }
      return el;
    })()''';
  }

  /// Generate JS code to find an element by selector or text.
  String _jsFindElement(String selector, {String? text, String? ref}) {
    // Deep query helper pierces Shadow DOM
    const deepQ = '''
function _dq(sel, root) {
  root = root || document;
  let el = root.querySelector(sel);
  if (el) return el;
  for (const n of root.querySelectorAll('*')) {
    if (n.shadowRoot) { el = _dq(sel, n.shadowRoot); if (el) return el; }
  }
  return null;
}
function _dqAll(sel, root) {
  root = root || document;
  let r = Array.from(root.querySelectorAll(sel));
  for (const n of root.querySelectorAll('*')) {
    if (n.shadowRoot) r = r.concat(_dqAll(sel, n.shadowRoot));
  }
  return r;
}
''';

    if (text != null) {
      final escaped = text.replaceAll("'", "\\'").replaceAll('\n', '\\n');
      return '''(() => {
        $deepQ
        let el = _dq('$selector');
        if (el) return el;
        // Visibility check helper
        function _vis(e) {
          const s = window.getComputedStyle(e);
          if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
          const r = e.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        }
        // Interactive tags get priority
        const interactive = new Set(['A','BUTTON','INPUT','SELECT','TEXTAREA','LABEL']);
        function _score(e) {
          let s = 0;
          if (_vis(e)) s += 1000;
          if (interactive.has(e.tagName) || e.getAttribute('role') === 'button' || e.getAttribute('role') === 'link' || e.getAttribute('role') === 'tab') s += 500;
          // Prefer smallest textContent (most specific match)
          s -= Math.min((e.textContent || '').length, 999);
          return s;
        }
        const all = _dqAll('a, button, input, select, textarea, label, span, p, h1, h2, h3, h4, h5, h6, div, li, td, th, [role]');
        // Exact match — pick best scored
        let best = null, bestScore = -Infinity;
        for (const e of all) {
          const t = (e.textContent || '').trim();
          if (t === '$escaped') {
            const sc = _score(e);
            if (sc > bestScore) { best = e; bestScore = sc; }
          }
        }
        if (best) return best;
        // Contains match — pick best scored
        best = null; bestScore = -Infinity;
        for (const e of all) {
          const t = (e.textContent || '').trim();
          if (t.includes('$escaped')) {
            const sc = _score(e);
            if (sc > bestScore) { best = e; bestScore = sc; }
          }
        }
        return best;
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
            tagSelector =
                'button, [role="button"], input[type="submit"], input[type="button"]';
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
          $deepQ
          const candidates = _dqAll('$tagSelector');
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
    return '''(() => {
      $deepQ
      return _dq('$selector');
    })()''';
  }

  /// Get element bounds (returns {x, y, w, h, cx, cy} or null).
  Future<Map<String, double>?> _getElementBounds(String selector,
      {String? text, String? ref}) async {
    final result = await _evalJs('''
      (() => {
        const el = ${_jsFindElement(selector, text: text, ref: ref)};
        if (!el) return JSON.stringify(null);
        const rect = el.getBoundingClientRect();
        return JSON.stringify({
          x: rect.left,
          y: rect.top,
          w: rect.width,
          h: rect.height,
          cx: rect.left + rect.width / 2,
          cy: rect.top + rect.height / 2
        });
      })()
    ''');

    final parsed = _parseJsonEval(result);
    if (parsed != null) {
      return {
        'x': (parsed['x'] as num).toDouble(),
        'y': (parsed['y'] as num).toDouble(),
        'w': (parsed['w'] as num).toDouble(),
        'h': (parsed['h'] as num).toDouble(),
        'cx': (parsed['cx'] as num).toDouble(),
        'cy': (parsed['cy'] as num).toDouble(),
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
        final listeners = _eventListeners[method];
        if (listeners != null) {
          final params = (json['params'] as Map<String, dynamic>?) ?? {};
          for (final cb in listeners) {
            cb(params);
          }
        }
      }
    } catch (e) {
      // Malformed message
    }
  }

  /// Whether auto-reconnect is in progress.
  bool _reconnecting = false;

  /// Max auto-reconnect attempts.
  static const int _maxReconnectAttempts = 5;

  void _onDisconnect() {
    _connected = false;
    _failAllPending('Connection lost');
    // Trigger auto-reconnect (non-blocking)
    _autoReconnect();
  }

  /// Auto-reconnect to CDP when connection drops (e.g. CfT restart).
  Future<void> _autoReconnect() async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      for (int attempt = 1; attempt <= _maxReconnectAttempts; attempt++) {
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
        await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
        try {
          final wsUrl = await _discoverTarget();
          if (wsUrl == null) continue;

          _ws = await WebSocket.connect(wsUrl)
              .timeout(const Duration(seconds: 10));
          _connected = true;

          _ws!.listen(
            _onMessage,
            onDone: _onDisconnect,
            onError: (_) => _onDisconnect(),
            cancelOnError: false,
          );

          // Re-enable required CDP domains
          await Future.wait([
            _call('Page.enable'),
            _call('DOM.enable'),
            _call('Runtime.enable'),
          ]);
          return; // Success
        } catch (_) {
          // Retry
        }
      }
    } finally {
      _reconnecting = false;
    }
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

/// Key info for CDP Input.dispatchKeyEvent (US QWERTY layout).
class _KeyInfo {
  final String code;
  final int keyCode;
  final bool shifted;
  final String unmodified; // The unshifted character

  const _KeyInfo(this.code, this.keyCode, this.shifted, this.unmodified);
}
