part of 'cdp_driver.dart';

/// Browser-specific CDP methods: cookies, storage, viewport,
/// tabs, frames, network, emulation, PDF, dialogs, etc.
extension CdpBrowserMethods on CdpDriver {
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

  // _dialogHandlerInstalled field is in CdpDriver class

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
    // Enforce max_tabs limit to prevent runaway tab creation
    try {
      final tabs = await getTabs();
      final tabList = tabs['tabs'] as List?;
      if (tabList != null && tabList.length >= _maxTabs) {
        return {"success": false, "error": "Max tabs limit reached ($_maxTabs). Close some tabs first."};
      }
    } catch (_) {}
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

  // _interceptRules field is in CdpDriver class

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

}
