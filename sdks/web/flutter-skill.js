/**
 * flutter-skill Web SDK
 *
 * Lightweight in-browser bridge that lets flutter-skill automate web apps.
 * Include this script in your page during development — it registers
 * window.__FLUTTER_SKILL__ and window.__FLUTTER_SKILL_CALL__ so the
 * flutter-skill proxy can interact with the DOM.
 *
 * Usage:
 *   <script src="https://unpkg.com/flutter-skill@latest/web/flutter-skill.js"></script>
 *
 * Or conditionally in your build:
 *   if (process.env.NODE_ENV === 'development') require('flutter-skill/web');
 */
(function () {
  "use strict";

  if (window.__FLUTTER_SKILL__) return; // already loaded

  // ---------------------------------------------------------------
  // Registry
  // ---------------------------------------------------------------
  var sdk = {
    version: "1.0.0",
    framework: "web",
  };
  window.__FLUTTER_SKILL__ = sdk;

  // ---------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------

  /** Find the best element matching key (data-testid / id) or visible text. */
  function findElement(params) {
    if (params.selector) {
      var el = document.querySelector(params.selector);
      return el || null;
    }
    if (params.key) {
      // data-testid first, then id
      var el =
        document.querySelector('[data-testid="' + params.key + '"]') ||
        document.getElementById(params.key);
      return el || null;
    }
    if (params.text) {
      // Walk visible elements looking for matching text
      var all = document.querySelectorAll(
        "button, a, input, textarea, select, [role=button], label, span, p, h1, h2, h3, h4, h5, h6, li, td, th, div"
      );
      for (var i = 0; i < all.length; i++) {
        var node = all[i];
        if (
          node.offsetParent !== null &&
          node.textContent &&
          node.textContent.trim().indexOf(params.text) !== -1
        ) {
          return node;
        }
      }
    }
    return null;
  }

  /** Build an element descriptor object. */
  function describeElement(el) {
    var rect = el.getBoundingClientRect();
    return {
      tag: el.tagName.toLowerCase(),
      id: el.id || null,
      testId: el.getAttribute("data-testid") || null,
      text: (el.textContent || "").trim().substring(0, 200),
      type: el.getAttribute("type") || null,
      role: el.getAttribute("role") || null,
      bounds: {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
      },
      visible: el.offsetParent !== null,
    };
  }

  // ---------------------------------------------------------------
  // Method implementations
  // ---------------------------------------------------------------

  var methods = {};

  methods.initialize = function () {
    return { success: true, framework: "web", sdk_version: sdk.version };
  };

  methods.inspect = function (params) {
    var selectors =
      "button, a, input, textarea, select, [role=button], [role=link], " +
      "[role=textbox], [role=checkbox], [role=radio], [role=tab], " +
      "[data-testid], [onclick]";
    var nodes = document.querySelectorAll(selectors);
    var elements = [];
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.offsetParent === null && el.tagName !== "INPUT") continue; // hidden
      elements.push(describeElement(el));
    }
    return { elements: elements };
  };

  methods.tap = function (params) {
    var el = findElement(params);
    if (!el) return { success: false, message: "Element not found" };
    el.click();
    return { success: true, message: "Tapped" };
  };

  methods.enter_text = function (params) {
    var el = findElement({ key: params.key, selector: params.selector });
    if (!el) return { success: false, message: "Element not found" };
    // Focus and set value
    el.focus();
    var nativeSetter = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype,
      "value"
    );
    if (!nativeSetter) {
      nativeSetter = Object.getOwnPropertyDescriptor(
        window.HTMLTextAreaElement.prototype,
        "value"
      );
    }
    if (nativeSetter && nativeSetter.set) {
      nativeSetter.set.call(el, params.text);
    } else {
      el.value = params.text;
    }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return { success: true, message: "Text entered" };
  };

  methods.swipe = function (params) {
    var target = params.key ? findElement({ key: params.key }) : document.body;
    if (!target) target = document.body;
    var rect = target.getBoundingClientRect();
    var cx = rect.x + rect.width / 2;
    var cy = rect.y + rect.height / 2;
    var dist = params.distance || 300;

    var dx = 0,
      dy = 0;
    switch (params.direction) {
      case "up":
        dy = -dist;
        break;
      case "down":
        dy = dist;
        break;
      case "left":
        dx = -dist;
        break;
      case "right":
        dx = dist;
        break;
    }

    target.dispatchEvent(
      new PointerEvent("pointerdown", {
        clientX: cx,
        clientY: cy,
        bubbles: true,
      })
    );
    target.dispatchEvent(
      new PointerEvent("pointermove", {
        clientX: cx + dx,
        clientY: cy + dy,
        bubbles: true,
      })
    );
    target.dispatchEvent(
      new PointerEvent("pointerup", {
        clientX: cx + dx,
        clientY: cy + dy,
        bubbles: true,
      })
    );
    return { success: true };
  };

  methods.scroll = function (params) {
    var target = params.key ? findElement({ key: params.key }) : window;
    var dist = params.distance || 300;
    var dir = params.direction || "down";
    var dx = 0,
      dy = 0;
    if (dir === "down") dy = dist;
    else if (dir === "up") dy = -dist;
    else if (dir === "right") dx = dist;
    else if (dir === "left") dx = -dist;

    if (target === window || target === document.body) {
      window.scrollBy(dx, dy);
    } else if (target) {
      target.scrollBy(dx, dy);
    }
    return { success: true };
  };

  methods.find_element = function (params) {
    var el = findElement(params);
    if (!el) return { found: false };
    return { found: true, element: describeElement(el) };
  };

  methods.get_text = function (params) {
    var el = findElement(params);
    if (!el) return { text: null };
    if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
      return { text: el.value };
    }
    return { text: (el.textContent || "").trim() };
  };

  methods.wait_for_element = function (params) {
    // Synchronous check — the proxy can retry with polling
    var el = findElement(params);
    return { found: !!el };
  };

  methods.screenshot = function () {
    // Cannot take a screenshot from inside the page.
    // Signal to the proxy that it should use CDP Page.captureScreenshot.
    return { _needs_cdp: true };
  };

  methods.get_logs = function () {
    return { logs: sdk._logs || [] };
  };

  methods.clear_logs = function () {
    sdk._logs = [];
    return { success: true };
  };

  // Capture console output
  sdk._logs = [];
  var origLog = console.log;
  var origWarn = console.warn;
  var origError = console.error;

  console.log = function () {
    sdk._logs.push("[LOG] " + Array.prototype.slice.call(arguments).join(" "));
    if (sdk._logs.length > 500) sdk._logs.shift();
    origLog.apply(console, arguments);
  };
  console.warn = function () {
    sdk._logs.push(
      "[WARN] " + Array.prototype.slice.call(arguments).join(" ")
    );
    if (sdk._logs.length > 500) sdk._logs.shift();
    origWarn.apply(console, arguments);
  };
  console.error = function () {
    sdk._logs.push(
      "[ERROR] " + Array.prototype.slice.call(arguments).join(" ")
    );
    if (sdk._logs.length > 500) sdk._logs.shift();
    origError.apply(console, arguments);
  };

  // ---------------------------------------------------------------
  // Dispatcher
  // ---------------------------------------------------------------

  /**
   * Called by the proxy via CDP Runtime.evaluate.
   * @param {string} method
   * @param {object} params
   * @returns {string} JSON-encoded result
   */
  window.__FLUTTER_SKILL_CALL__ = function (method, params) {
    params = params || {};
    var fn = methods[method];
    if (!fn) {
      return JSON.stringify({ error: "Unknown method: " + method });
    }
    try {
      var result = fn(params);
      return JSON.stringify(result);
    } catch (e) {
      return JSON.stringify({ error: e.message || String(e) });
    }
  };
})();
