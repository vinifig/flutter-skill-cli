/**
 * Flutter Skill Web SDK — browser-ready bridge for vanilla web apps.
 * Include via <script src="flutter-skill-web.js"></script>
 * Zero dependencies. Pure browser JavaScript.
 */
(function () {
  'use strict';

  var SDK_VERSION = '1.0.0';
  var DEFAULT_PORT = 18118;
  var RECONNECT_DELAY = 2000;

  // --------------- Element cache ---------------
  var _elementCache = {};
  var _cacheId = 0;

  function cacheElement(el) {
    var id = '__fs_' + (++_cacheId);
    _elementCache[id] = el;
    return id;
  }

  function getCachedElement(id) {
    return _elementCache[id] || null;
  }

  // --------------- DOM helpers ---------------

  function isVisible(el) {
    if (!el || el.nodeType !== 1) return false;
    var s = window.getComputedStyle(el);
    return s.display !== 'none' && s.visibility !== 'hidden' && s.opacity !== '0';
  }

  function getElementType(el) {
    var tag = el.tagName.toLowerCase();
    if (tag === 'button' || el.matches('[role="button"]') || el.onclick) return 'button';
    if (tag === 'input') {
      var t = (el.type || 'text').toLowerCase();
      if (t === 'checkbox') return 'checkbox';
      if (t === 'radio') return 'radio';
      if (['text','email','password','search','number','tel','url'].indexOf(t) !== -1) return 'text_field';
      if (t === 'range') return 'slider';
      if (t === 'file') return 'button';
      return 'button';
    }
    if (tag === 'textarea') return 'text_field';
    if (tag === 'select') return 'dropdown';
    if (tag === 'a' && el.href) return 'link';
    if (el.matches('[role="tab"]')) return 'tab';
    if (el.matches('[role="switch"]')) return 'switch';
    if (el.matches('[role="slider"]')) return 'slider';
    if (el.matches('[role="listitem"]') || tag === 'li') return 'list_item';
    return 'button';
  }

  var _roleMap = {
    button: 'button', text_field: 'input', checkbox: 'toggle', switch: 'toggle',
    radio: 'toggle', slider: 'slider', dropdown: 'select', link: 'link',
    list_item: 'item', tab: 'item'
  };

  function generateSemanticRef(el, type, refCounts) {
    var role = _roleMap[type] || 'element';
    var content = el.id ||
      el.getAttribute('aria-label') ||
      (el.textContent && el.textContent.trim()) ||
      el.getAttribute('placeholder') ||
      el.getAttribute('title') || null;

    if (content) {
      content = content.replace(/\s+/g, '_').replace(/[^\w]/g, '').substring(0, 30);
      if (content.length > 27) content = content.substring(0, 27) + '...';
      var base = role + ':' + content;
      var c = refCounts[base] || 0;
      refCounts[base] = c + 1;
      return c === 0 ? base : base + '[' + c + ']';
    }
    var rc = refCounts[role] || 0;
    refCounts[role] = rc + 1;
    return role + '[' + rc + ']';
  }

  function isInteractive(el) {
    return el.matches('button, input, select, textarea, a[href], [role="button"], [onclick], [role="tab"], [role="switch"], [role="slider"], li[onclick]') || el.onclick != null;
  }

  function walkInteractive(root, callback) {
    if (!root || root.nodeType !== 1) return;
    if (!isVisible(root)) return;
    if (isInteractive(root)) callback(root);
    for (var i = 0; i < root.children.length; i++) {
      walkInteractive(root.children[i], callback);
    }
  }

  function walkAll(root, callback) {
    if (!root || root.nodeType !== 1) return;
    if (!isVisible(root)) return;
    var tag = root.tagName.toLowerCase();
    var inter = isInteractive(root);
    var hasId = !!root.id;
    var hasText = !root.children.length && (root.textContent || '').trim().length > 0;
    if (inter || hasId || hasText) callback(root);
    for (var i = 0; i < root.children.length; i++) {
      walkAll(root.children[i], callback);
    }
  }

  function mapTypeBasic(el) {
    var tag = el.tagName.toLowerCase();
    if (tag === 'button' || el.matches('[role="button"]')) return 'button';
    if (tag === 'input') {
      var t = el.type;
      if (t === 'checkbox') return 'checkbox';
      if (t === 'radio') return 'radio';
      if ('text email password search number'.split(' ').indexOf(t) !== -1) return 'text_field';
      return 'input';
    }
    if (tag === 'textarea') return 'text_field';
    if (tag === 'select') return 'dropdown';
    if (tag === 'a') return 'link';
    if (tag === 'img') return 'image';
    if (tag === 'label') return 'label';
    if (tag === 'h1' || tag === 'h2' || tag === 'h3') return 'heading';
    return 'text';
  }

  // --------------- Resolve element by ref/selector/text ---------------

  function resolveElement(params) {
    var el = null;

    // By cacheId
    if (params.cacheId) {
      el = getCachedElement(params.cacheId);
      if (el) return el;
    }

    // By ref
    if (params.ref) {
      var refCounts = {};
      walkInteractive(document.body, function (e) {
        var type = getElementType(e);
        var ref = generateSemanticRef(e, type, refCounts);
        if (ref === params.ref) el = e;
      });
      if (el) return el;
    }

    // By selector / key
    var sel = params.selector || (params.key ? '#' + params.key : null) || params.element;
    if (sel) {
      el = document.querySelector(sel);
      if (el) return el;
    }

    // By text
    if (params.text) {
      var tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      while (tw.nextNode()) {
        if (tw.currentNode.textContent.indexOf(params.text) !== -1) {
          return tw.currentNode.parentElement;
        }
      }
    }

    return null;
  }

  // --------------- Screenshot helpers ---------------

  function screenshotFull() {
    // Simple DOM-info screenshot — avoids SVG foreignObject hangs and huge payloads
    var w = window.innerWidth;
    var h = window.innerHeight;
    var canvas = document.createElement('canvas');
    // Use 1x scale to keep payload small (~50KB vs 1MB+ at 2x DPR)
    canvas.width = Math.min(w, 800);
    canvas.height = Math.min(h, 600);
    var ctx = canvas.getContext('2d');
    var scaleX = canvas.width / w;
    var scaleY = canvas.height / h;
    ctx.scale(scaleX, scaleY);

    // Draw page background
    var bg = getComputedStyle(document.body).backgroundColor || '#ffffff';
    ctx.fillStyle = bg === 'rgba(0, 0, 0, 0)' ? '#ffffff' : bg;
    ctx.fillRect(0, 0, w, h);

    // Draw visible text elements as a lightweight representation
    ctx.fillStyle = '#000000';
    ctx.font = '14px sans-serif';
    var y = 30;
    var els = document.querySelectorAll('h1,h2,h3,p,button,a,input,label,span');
    for (var i = 0; i < Math.min(els.length, 40); i++) {
      var el = els[i];
      var rect = el.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) continue;
      var tag = el.tagName.toLowerCase();
      var txt = (el.textContent || '').trim().substring(0, 60);
      if (!txt && el.placeholder) txt = '[' + el.placeholder + ']';
      if (!txt) continue;
      // Draw element representation at its approximate position
      if (tag === 'button' || tag === 'a') {
        ctx.fillStyle = '#0066cc';
        ctx.fillRect(rect.x, rect.y, rect.width, rect.height);
        ctx.fillStyle = '#ffffff';
        ctx.fillText(txt, rect.x + 4, rect.y + 16);
        ctx.fillStyle = '#000000';
      } else if (tag === 'input') {
        ctx.strokeStyle = '#999999';
        ctx.strokeRect(rect.x, rect.y, rect.width, rect.height);
        ctx.fillText(txt || el.value || '', rect.x + 4, rect.y + 16);
      } else {
        ctx.fillText(txt, rect.x, rect.y + 14);
      }
    }

    // Return as JPEG for smaller size
    return Promise.resolve(canvas.toDataURL('image/jpeg', 0.6).split(',')[1]);
  }

  function screenshotRegion(x, y, width, height) {
    return screenshotFull().then(function (base64) {
      return new Promise(function (resolve) {
        var img = new Image();
        img.onload = function () {
          var canvas = document.createElement('canvas');
          canvas.width = width;
          canvas.height = height;
          var ctx = canvas.getContext('2d');
          ctx.drawImage(img, x, y, width, height, 0, 0, width, height);
          resolve(canvas.toDataURL('image/png').split(',')[1]);
        };
        img.src = 'data:image/png;base64,' + base64;
      });
    });
  }

  function screenshotElement(params) {
    var el = resolveElement(params);
    if (!el) return Promise.resolve({ success: false, message: 'Element not found' });
    var rect = el.getBoundingClientRect();
    return screenshotRegion(Math.round(rect.x), Math.round(rect.y), Math.round(rect.width), Math.round(rect.height))
      .then(function (b64) { return { success: true, image: b64, format: 'png', encoding: 'base64' }; });
  }

  // --------------- Method handlers ---------------

  var handlers = {};

  handlers.initialize = function () {
    return { success: true, framework: 'web', sdk_version: SDK_VERSION, platform: 'web' };
  };

  handlers.inspect = function () {
    var elements = [];
    walkAll(document.body, function (el) {
      var rect = el.getBoundingClientRect();
      elements.push({
        type: mapTypeBasic(el),
        key: el.id || null,
        tag: el.tagName.toLowerCase(),
        text: (el.value || el.textContent || '').trim().slice(0, 200) || null,
        bounds: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
        visible: rect.width > 0 && rect.height > 0,
        enabled: !el.disabled,
        clickable: el.matches('button, a, [role="button"], [onclick]') || el.onclick != null
      });
    });
    return { elements: elements };
  };

  handlers.inspect_interactive = function () {
    var elements = [];
    var refCounts = {};
    walkInteractive(document.body, function (el) {
      var type = getElementType(el);
      var rect = el.getBoundingClientRect();
      var text = (el.textContent || el.value || el.alt || el.title || '').trim();
      var label = el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || '';
      var ref = generateSemanticRef(el, type, refCounts);

      var actions = ['tap'];
      if (type === 'text_field') actions = ['tap', 'enter_text'];
      else if (type === 'slider') actions = ['tap', 'swipe'];
      else actions.push('long_press');

      var elem = {
        ref: ref,
        type: el.tagName + (el.type ? '[' + el.type + ']' : ''),
        text: text.slice(0, 100) || null,
        actions: actions,
        enabled: !el.disabled && !el.readOnly,
        bounds: { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) }
      };
      if (label) elem.label = label;
      // value
      if (type === 'text_field') elem.value = el.value || '';
      else if (type === 'checkbox' || type === 'switch') elem.value = el.checked || false;
      else if (type === 'dropdown') elem.value = el.value || '';
      else if (type === 'slider') elem.value = parseFloat(el.value) || 0;

      elem._cacheId = cacheElement(el);
      elements.push(elem);
    });

    return { elements: elements, summary: elements.length + ' interactive elements' };
  };

  handlers.tap = function (params) {
    var el = resolveElement(params);
    if (!el) return { success: false, message: 'Element not found' };
    el.click();
    return { success: true };
  };

  handlers.enter_text = function (params) {
    var el = resolveElement(params);
    if (!el) return { success: false, message: 'Element not found' };
    el.focus();
    if (el.matches('input, textarea')) {
      el.value = params.text || '';
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } else if (el.isContentEditable) {
      el.textContent = params.text || '';
      el.dispatchEvent(new Event('input', { bubbles: true }));
    } else {
      return { success: false, message: 'Element is not a text input' };
    }
    return { success: true };
  };

  handlers.get_text = function (params) {
    var el = resolveElement(params);
    if (!el) return { text: null };
    return { text: (el.value || el.textContent || '').trim() };
  };

  handlers.get_checkbox_state = function (params) {
    var el = resolveElement(params);
    if (!el) return { success: false, message: 'Element not found' };
    // Handle toggle buttons (class-based)
    if (el.classList && el.classList.contains('toggle')) {
      return { checked: el.classList.contains('on') };
    }
    return { checked: !!el.checked };
  };

  handlers.get_slider_value = function (params) {
    var el = resolveElement(params);
    if (!el) return { success: false, message: 'Element not found' };
    return { value: parseFloat(el.value) || 0, min: parseFloat(el.min) || 0, max: parseFloat(el.max) || 100 };
  };

  handlers.scroll_to = function (params) {
    var el = resolveElement(params);
    if (el) {
      el.scrollIntoView({ behavior: 'smooth', block: 'center' });
      return { success: true };
    }
    // Directional scroll
    var direction = params.direction || 'down';
    var distance = params.distance || 300;
    var dx = 0, dy = 0;
    if (direction === 'up') dy = -distance;
    else if (direction === 'down') dy = distance;
    else if (direction === 'left') dx = -distance;
    else if (direction === 'right') dx = distance;

    var container = document.scrollingElement || document.body;
    if (params.selector || params.key) {
      var c = document.querySelector(params.selector || '#' + params.key);
      if (c) container = c;
    }
    container.scrollBy(dx, dy);
    return { success: true };
  };
  handlers.scroll = handlers.scroll_to;

  handlers.long_press = function (params) {
    var el = resolveElement(params);
    if (!el) return { success: false, message: 'Element not found' };
    // Simulate via pointerdown + delay + pointerup
    el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
    el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
    return new Promise(function (resolve) {
      setTimeout(function () {
        el.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }));
        el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
        el.dispatchEvent(new Event('contextmenu', { bubbles: true }));
        resolve({ success: true });
      }, params.duration || 500);
    });
  };

  handlers.double_tap = function (params) {
    var el = resolveElement(params);
    if (!el) return { success: false, message: 'Element not found' };
    el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
    return { success: true };
  };

  handlers.swipe = function (params) {
    var direction = params.direction || 'up';
    var distance = params.distance || 300;
    var startX = params.startX || window.innerWidth / 2;
    var startY = params.startY || window.innerHeight / 2;
    var endX = startX, endY = startY;
    if (direction === 'up') endY -= distance;
    else if (direction === 'down') endY += distance;
    else if (direction === 'left') endX -= distance;
    else if (direction === 'right') endX += distance;

    var target = document.elementFromPoint(startX, startY) || document.body;
    target.dispatchEvent(new TouchEvent('touchstart', {
      bubbles: true, touches: [new Touch({ identifier: 0, target: target, clientX: startX, clientY: startY })]
    }));
    target.dispatchEvent(new TouchEvent('touchmove', {
      bubbles: true, touches: [new Touch({ identifier: 0, target: target, clientX: endX, clientY: endY })]
    }));
    target.dispatchEvent(new TouchEvent('touchend', { bubbles: true, changedTouches: [new Touch({ identifier: 0, target: target, clientX: endX, clientY: endY })] }));

    // Also scroll
    var container = document.scrollingElement || document.body;
    if (direction === 'up') container.scrollBy(0, -distance);
    else if (direction === 'down') container.scrollBy(0, distance);
    else if (direction === 'left') container.scrollBy(-distance, 0);
    else if (direction === 'right') container.scrollBy(distance, 0);

    return { success: true };
  };

  handlers.drag = function (params) {
    var startX = params.startX || 0, startY = params.startY || 0;
    var endX = params.endX || 0, endY = params.endY || 0;
    var target = document.elementFromPoint(startX, startY) || document.body;
    target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: startX, clientY: startY }));
    target.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: endX, clientY: endY }));
    target.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: endX, clientY: endY }));
    return { success: true };
  };

  handlers.go_back = function () {
    // Try custom handler
    if (typeof window.__flutterSkillGoBack === 'function') {
      window.__flutterSkillGoBack();
      return { success: true };
    }
    // Try back buttons
    var backBtns = document.querySelectorAll('[id*="back"], [class*="back"], [aria-label*="back"], [aria-label*="Back"]');
    for (var i = 0; i < backBtns.length; i++) {
      if (backBtns[i].offsetParent !== null) { backBtns[i].click(); return { success: true }; }
    }
    window.history.back();
    return { success: true };
  };

  handlers.screenshot = function () {
    return screenshotFull().then(function (b64) {
      return { success: true, image: b64, format: 'png', encoding: 'base64' };
    });
  };

  handlers.screenshot_region = function (params) {
    return screenshotRegion(params.x || 0, params.y || 0, params.width || 300, params.height || 300)
      .then(function (b64) { return { success: true, image: b64, format: 'png', encoding: 'base64' }; });
  };

  handlers.screenshot_element = function (params) {
    return screenshotElement(params);
  };

  // --------------- State for monitoring ---------------
  var _testIndicatorsEnabled = false;
  var _networkMonitoringEnabled = false;
  var _capturedNetworkRequests = [];
  var _capturedErrors = [];

  // Capture console.error entries
  var _origConsoleError = console.error;
  console.error = function () {
    var msg = Array.prototype.slice.call(arguments).join(' ');
    _capturedErrors.push({ timestamp: Date.now(), message: msg });
    if (_capturedErrors.length > 200) _capturedErrors.shift();
    _origConsoleError.apply(console, arguments);
  };

  handlers.tap_at = function (params) {
    var x = params.x || 0, y = params.y || 0;
    var el = document.elementFromPoint(x, y) || document.body;
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: x, clientY: y }));
    return { success: true };
  };

  handlers.long_press_at = function (params) {
    var x = params.x || 0, y = params.y || 0;
    var duration = params.duration || 500;
    var el = document.elementFromPoint(x, y) || document.body;
    el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: x, clientY: y }));
    el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: x, clientY: y }));
    return new Promise(function (resolve) {
      setTimeout(function () {
        el.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, clientX: x, clientY: y }));
        el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: x, clientY: y }));
        resolve({ success: true });
      }, duration);
    });
  };

  handlers.edge_swipe = function (params) {
    var edge = params.edge || 'left';
    var distance = params.distance || 200;
    var w = window.innerWidth, h = window.innerHeight;
    var startX, startY, endX, endY;
    if (edge === 'left') { startX = 0; startY = h / 2; endX = distance; endY = h / 2; }
    else if (edge === 'right') { startX = w; startY = h / 2; endX = w - distance; endY = h / 2; }
    else if (edge === 'top') { startX = w / 2; startY = 0; endX = w / 2; endY = distance; }
    else { startX = w / 2; startY = h; endX = w / 2; endY = h - distance; }
    var target = document.elementFromPoint(startX, startY) || document.body;
    target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: startX, clientY: startY }));
    target.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: endX, clientY: endY }));
    target.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: endX, clientY: endY }));
    return { success: true };
  };

  handlers.gesture = function (params) {
    var actions = params.actions || [];
    return new Promise(function (resolve) {
      var i = 0;
      function next() {
        if (i >= actions.length) return resolve({ success: true });
        var a = actions[i++];
        if (a.type === 'tap') {
          var el = document.elementFromPoint(a.x || 0, a.y || 0) || document.body;
          el.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: a.x || 0, clientY: a.y || 0 }));
          next();
        } else if (a.type === 'swipe') {
          var t = document.elementFromPoint(a.startX || a.x || 0, a.startY || a.y || 0) || document.body;
          t.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: a.startX || a.x || 0, clientY: a.startY || a.y || 0 }));
          t.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: a.endX || 0, clientY: a.endY || 0 }));
          t.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: a.endX || 0, clientY: a.endY || 0 }));
          next();
        } else if (a.type === 'wait') {
          setTimeout(next, a.duration || a.ms || 500);
        } else {
          next();
        }
      }
      next();
    });
  };

  handlers.scroll_until_visible = function (params) {
    var direction = params.direction || 'down';
    var maxScrolls = params.maxScrolls || 10;
    return new Promise(function (resolve) {
      var count = 0;
      function attempt() {
        var el = resolveElement(params);
        if (el && isVisible(el)) return resolve({ success: true });
        if (count >= maxScrolls) return resolve({ success: false });
        count++;
        var container = document.scrollingElement || document.body;
        var dy = direction === 'down' ? 300 : direction === 'up' ? -300 : 0;
        var dx = direction === 'right' ? 300 : direction === 'left' ? -300 : 0;
        container.scrollBy(dx, dy);
        setTimeout(attempt, 200);
      }
      attempt();
    });
  };

  handlers.swipe_coordinates = function (params) {
    var startX = params.startX || 0, startY = params.startY || 0;
    var endX = params.endX || 0, endY = params.endY || 0;
    var target = document.elementFromPoint(startX, startY) || document.body;
    target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: startX, clientY: startY }));
    target.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: endX, clientY: endY }));
    target.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: endX, clientY: endY }));
    return { success: true };
  };

  handlers.get_route = function () {
    return { route: window.location.hash || window.location.pathname };
  };

  handlers.get_navigation_stack = function () {
    var route = window.location.hash || window.location.pathname;
    return { stack: [route], length: 1 };
  };

  handlers.get_errors = function () {
    return { errors: _capturedErrors.slice() };
  };

  handlers.get_performance = function () {
    var fps = 60, frameTime = 16.6;
    if (window.performance && window.performance.now) {
      var entries = window.performance.getEntriesByType ? window.performance.getEntriesByType('frame') : [];
      if (entries.length > 1) {
        var last = entries[entries.length - 1];
        var prev = entries[entries.length - 2];
        frameTime = last.startTime - prev.startTime;
        fps = Math.round(1000 / frameTime);
      }
    }
    return { fps: fps, frameTime: frameTime };
  };

  handlers.get_frame_stats = function () {
    var entries = (window.performance && window.performance.getEntriesByType) ? window.performance.getEntriesByType('navigation') : [];
    var nav = entries[0] || {};
    return {
      now: window.performance ? window.performance.now() : 0,
      navigationStart: nav.startTime || 0,
      domContentLoaded: nav.domContentLoadedEventEnd || 0,
      loadComplete: nav.loadEventEnd || 0
    };
  };

  handlers.get_memory_stats = function () {
    if (window.performance && window.performance.memory) {
      return {
        usedJSHeapSize: window.performance.memory.usedJSHeapSize,
        totalJSHeapSize: window.performance.memory.totalJSHeapSize,
        jsHeapSizeLimit: window.performance.memory.jsHeapSizeLimit
      };
    }
    return { usedJSHeapSize: 0, totalJSHeapSize: 0, jsHeapSizeLimit: 0 };
  };

  handlers.wait_for_gone = function (params) {
    var timeout = params.timeout || 5000;
    return new Promise(function (resolve) {
      var start = Date.now();
      function check() {
        var el = resolveElement(params);
        if (!el || !isVisible(el)) return resolve({ success: true });
        if (Date.now() - start > timeout) return resolve({ success: false });
        requestAnimationFrame(check);
      }
      check();
    });
  };

  handlers.diagnose = function () {
    var count = 0;
    walkAll(document.body, function () { count++; });
    return {
      platform: 'web',
      elements: count,
      url: window.location.href,
      userAgent: navigator.userAgent,
      viewport: { width: window.innerWidth, height: window.innerHeight }
    };
  };

  handlers.enable_test_indicators = function () {
    if (!_testIndicatorsEnabled) {
      _testIndicatorsEnabled = true;
      document.addEventListener('click', function (e) {
        if (!_testIndicatorsEnabled) return;
        var dot = document.createElement('div');
        dot.style.cssText = 'position:fixed;left:' + (e.clientX - 10) + 'px;top:' + (e.clientY - 10) + 'px;width:20px;height:20px;border-radius:50%;background:rgba(255,0,0,0.5);pointer-events:none;z-index:999999;transition:opacity 0.5s;';
        document.body.appendChild(dot);
        setTimeout(function () { dot.style.opacity = '0'; }, 300);
        setTimeout(function () { dot.remove(); }, 800);
      }, true);
    }
    return { success: true };
  };

  handlers.get_indicator_status = function () {
    return { enabled: _testIndicatorsEnabled };
  };

  handlers.enable_network_monitoring = function () {
    if (!_networkMonitoringEnabled) {
      _networkMonitoringEnabled = true;
      var origFetch = window.fetch;
      window.fetch = function () {
        var url = arguments[0];
        if (typeof url === 'object' && url.url) url = url.url;
        var entry = { type: 'fetch', url: String(url), timestamp: Date.now(), status: null };
        _capturedNetworkRequests.push(entry);
        return origFetch.apply(window, arguments).then(function (resp) {
          entry.status = resp.status;
          return resp;
        }).catch(function (err) {
          entry.error = err.message;
          throw err;
        });
      };
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this._fsUrl = url;
        this._fsMethod = method;
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        var entry = { type: 'xhr', url: String(this._fsUrl), method: this._fsMethod, timestamp: Date.now(), status: null };
        _capturedNetworkRequests.push(entry);
        var xhr = this;
        xhr.addEventListener('load', function () { entry.status = xhr.status; });
        xhr.addEventListener('error', function () { entry.error = 'network error'; });
        return origSend.apply(this, arguments);
      };
    }
    return { success: true };
  };

  handlers.get_network_requests = function () {
    return { requests: _capturedNetworkRequests.slice() };
  };

  handlers.clear_network_requests = function () {
    _capturedNetworkRequests = [];
    return { success: true };
  };

  handlers.eval = function (params) {
    try {
      var result = eval(params.expression || params.code || '');
      return { success: true, result: result !== undefined ? String(result) : null };
    } catch (e) {
      return { success: false, error: e.message };
    }
  };

  handlers.press_key = function (params) {
    var keyName = params.key;
    if (!keyName) return { success: false, error: 'Missing key' };
    var modifiers = params.modifiers || [];
    var keyMap = {
      enter: 'Enter', tab: 'Tab', escape: 'Escape', backspace: 'Backspace',
      delete: 'Delete', space: ' ', up: 'ArrowUp', down: 'ArrowDown',
      left: 'ArrowLeft', right: 'ArrowRight', home: 'Home', end: 'End',
      pageup: 'PageUp', pagedown: 'PageDown'
    };
    var mapped = keyMap[keyName.toLowerCase()] || keyName;
    var target = document.activeElement || document.body;
    var opts = {
      key: mapped, code: mapped, bubbles: true, cancelable: true,
      ctrlKey: modifiers.indexOf('ctrl') !== -1,
      metaKey: modifiers.indexOf('meta') !== -1,
      shiftKey: modifiers.indexOf('shift') !== -1,
      altKey: modifiers.indexOf('alt') !== -1
    };
    target.dispatchEvent(new KeyboardEvent('keydown', opts));
    if (mapped === 'Enter') target.dispatchEvent(new KeyboardEvent('keypress', opts));
    target.dispatchEvent(new KeyboardEvent('keyup', opts));
    return { success: true };
  };

  handlers.get_elements_by_type = function (params) {
    var targetType = params.type || 'button';
    var elements = [];
    var refCounts = {};
    walkInteractive(document.body, function (el) {
      var type = getElementType(el);
      if (type === targetType) {
        var rect = el.getBoundingClientRect();
        var ref = generateSemanticRef(el, type, refCounts);
        elements.push({
          ref: ref,
          type: type,
          text: (el.textContent || el.value || '').trim().slice(0, 100) || null,
          bounds: { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) }
        });
      }
    });
    return { elements: elements };
  };

  handlers.find_element = function (params) {
    var el = resolveElement(params);
    if (!el) return { found: false };
    var rect = el.getBoundingClientRect();
    return {
      found: true,
      element: {
        tag: el.tagName.toLowerCase(),
        key: el.id || null,
        text: (el.value || el.textContent || '').trim().slice(0, 200),
        bounds: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) }
      }
    };
  };

  handlers.wait_for_element = function (params) {
    var timeout = params.timeout || 5000;
    return new Promise(function (resolve) {
      var start = Date.now();
      function check() {
        var el = resolveElement(params);
        if (el) return resolve({ found: true });
        if (Date.now() - start > timeout) return resolve({ found: false });
        requestAnimationFrame(check);
      }
      check();
    });
  };

  handlers.get_logs = function () {
    return { logs: _logs.slice() };
  };

  handlers.clear_logs = function () {
    _logs = [];
    return { success: true };
  };

  // --------------- Logs ---------------
  var _logs = [];
  var _maxLogs = 500;

  function addLog(level, msg) {
    _logs.push('[' + level + '] ' + msg);
    if (_logs.length > _maxLogs) _logs.shift();
  }

  // --------------- WebSocket bridge ---------------

  var _ws = null;
  var _port = (window.FLUTTER_SKILL_PORT || DEFAULT_PORT);
  var _appName = window.FLUTTER_SKILL_APP_NAME || document.title || 'web-app';
  var _reconnectTimer = null;

  function connect() {
    if (_ws && (_ws.readyState === WebSocket.CONNECTING || _ws.readyState === WebSocket.OPEN)) return;

    try {
      _ws = new WebSocket('ws://127.0.0.1:' + _port);
    } catch (e) {
      scheduleReconnect();
      return;
    }

    _ws.onopen = function () {
      addLog('info', 'Connected to MCP server on port ' + _port);
      console.log('[flutter-skill-web] Connected on port ' + _port);
      // Send health/handshake
      _ws.send(JSON.stringify({
        jsonrpc: '2.0',
        method: 'bridge.hello',
        params: {
          framework: 'web',
          app_name: _appName,
          platform: 'web',
          sdk_version: SDK_VERSION,
          capabilities: Object.keys(handlers)
        }
      }));
    };

    _ws.onmessage = function (evt) {
      // Handle text ping keepalive
      if (evt.data === 'ping') { try { _ws.send('pong'); } catch (_) {} return; }
      var req;
      try { req = JSON.parse(evt.data); } catch (e) {
        _ws.send(JSON.stringify({ jsonrpc: '2.0', error: { code: -32700, message: 'Parse error' }, id: null }));
        return;
      }

      var method = req.method;
      var params = req.params || {};
      var id = req.id;

      if (!handlers[method]) {
        _ws.send(JSON.stringify({ jsonrpc: '2.0', error: { code: -32601, message: 'Unknown method: ' + method }, id: id }));
        return;
      }

      try {
        var result = handlers[method](params);
        if (result && typeof result.then === 'function') {
          result.then(function (r) {
            _ws.send(JSON.stringify({ jsonrpc: '2.0', result: r, id: id }));
          }).catch(function (e) {
            _ws.send(JSON.stringify({ jsonrpc: '2.0', error: { code: -32000, message: e.message || String(e) }, id: id }));
          });
        } else {
          _ws.send(JSON.stringify({ jsonrpc: '2.0', result: result, id: id }));
        }
      } catch (e) {
        _ws.send(JSON.stringify({ jsonrpc: '2.0', error: { code: -32000, message: e.message || String(e) }, id: id }));
      }
    };

    _ws.onclose = function () {
      addLog('info', 'Disconnected');
      scheduleReconnect();
    };

    _ws.onerror = function () {
      scheduleReconnect();
    };
  }

  function scheduleReconnect() {
    if (_reconnectTimer) return;
    _reconnectTimer = setTimeout(function () {
      _reconnectTimer = null;
      connect();
    }, RECONNECT_DELAY);
  }

  // --------------- Health endpoint via fetch intercept ---------------
  // Since browsers can't create HTTP servers, we expose health info on window
  window.__flutterSkillHealth = function () {
    return {
      framework: 'web',
      app_name: _appName,
      platform: 'web',
      sdk_version: SDK_VERSION,
      capabilities: Object.keys(handlers)
    };
  };

  // --------------- Public API ---------------
  window.FlutterSkillWeb = {
    version: SDK_VERSION,
    connect: connect,
    disconnect: function () {
      if (_reconnectTimer) { clearTimeout(_reconnectTimer); _reconnectTimer = null; }
      if (_ws) _ws.close();
    },
    health: window.__flutterSkillHealth,
    handlers: handlers
  };

  // Auto-connect on load
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', connect);
  } else {
    connect();
  }

})();
