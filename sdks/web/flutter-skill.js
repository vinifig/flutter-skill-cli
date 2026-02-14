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

  /** Find the best element matching key (data-testid / id), visible text, or semantic ref. */
  function findElement(params) {
    if (params.selector) {
      var el = document.querySelector(params.selector);
      return el || null;
    }
    
    // Handle semantic ref ID (new system)
    if (params.ref) {
      return findElementByRef(params.ref);
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

  /** Find element by semantic ref ID - regenerates refs and matches */
  function findElementByRef(refId) {
    // Check if this is a legacy ref format (btn_0, tf_1, etc.)
    if (/^[a-z]+_\d+$/.test(refId)) {
      return findElementByLegacyRef(refId);
    }
    
    // For semantic refs, we need to regenerate the inspect data and match
    var inspectResult = methods.inspect_interactive({});
    var elements = inspectResult.elements;
    
    for (var i = 0; i < elements.length; i++) {
      if (elements[i].ref === refId) {
        // Found matching ref, now find the actual DOM element
        var bounds = elements[i].bounds;
        // Use document.elementFromPoint with center of element bounds
        var centerX = bounds.x + bounds.w / 2;
        var centerY = bounds.y + bounds.h / 2;
        var el = document.elementFromPoint(centerX, centerY);
        return el;
      }
    }
    
    return null;
  }

  /** Handle legacy ref format for backward compatibility */
  function findElementByLegacyRef(refId) {
    var parts = refId.split('_');
    if (parts.length !== 2) return null;
    
    var prefix = parts[0];
    var index = parseInt(parts[1]);
    
    // Map old prefixes to new roles
    var roleMap = {
      btn: 'button',
      tf: 'input', 
      sw: 'toggle',
      sl: 'slider',
      dd: 'select',
      lnk: 'link',
      item: 'item'
    };
    
    var role = roleMap[prefix];
    if (!role) return null;
    
    // Regenerate inspect data and find elements of matching role
    var inspectResult = methods.inspect_interactive({});
    var elements = inspectResult.elements;
    var matchingElements = [];
    
    for (var i = 0; i < elements.length; i++) {
      var ref = elements[i].ref;
      if (ref.startsWith(role + ':')) {
        matchingElements.push(elements[i]);
      }
    }
    
    if (matchingElements.length === 0 || index >= matchingElements.length) {
      return null;
    }
    
    // Get element at legacy index
    var targetElement = matchingElements[index];
    var bounds = targetElement.bounds;
    var centerX = bounds.x + bounds.w / 2;
    var centerY = bounds.y + bounds.h / 2;
    return document.elementFromPoint(centerX, centerY);
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

  methods.inspect_interactive = function (params) {
    var elements = [];
    var refCounts = {};

    // Semantic ref generation system - generates {role}:{content}[{index}] format
    function generateSemanticRefId(el, elementType) {
      // Map element types to semantic roles
      var role = {
        button: "button",
        text_field: "input", 
        checkbox: "toggle",
        switch: "toggle",
        radio: "toggle",
        slider: "slider",
        dropdown: "select",
        link: "link",
        list_item: "item",
        tab: "item"
      }[elementType] || "element";

      // Extract content with priority: data-testid > aria-label > text > placeholder > fallback
      var content = el.getAttribute("data-testid") ||
                   el.getAttribute("aria-label") ||
                   (el.textContent && el.textContent.trim()) ||
                   el.getAttribute("placeholder") ||
                   el.getAttribute("title") ||
                   null;

      if (content) {
        // Clean and format content (replace spaces with underscores, remove special chars)
        content = content.replace(/\s+/g, '_')
                        .replace(/[^\w]/g, '')
                        .substring(0, 30);
        if (content.length > 27) {
          content = content.substring(0, 27) + '...';
        }

        var baseRef = role + ':' + content;
        var count = refCounts[baseRef] || 0;
        refCounts[baseRef] = count + 1;

        return count === 0 ? baseRef : baseRef + '[' + count + ']';
      } else {
        // No content - use role + index fallback
        var count = refCounts[role] || 0;
        refCounts[role] = count + 1;
        return role + '[' + count + ']';
      }
    }

    function getElementType(el) {
      var tag = el.tagName.toLowerCase();
      var type = el.type ? el.type.toLowerCase() : "";
      var role = el.getAttribute("role") || "";

      if (tag === "button" || role === "button" || el.onclick) return "button";
      if (tag === "input") {
        if (["checkbox", "radio"].includes(type)) return type;
        if (["text", "email", "password", "search", "number", "tel", "url"].includes(type)) return "text_field";
        if (type === "range") return "slider";
        return "button";
      }
      if (tag === "textarea") return "text_field";
      if (tag === "select") return "dropdown";
      if (tag === "a" && el.href) return "link";
      if (role === "tab" || el.closest('[role="tablist"]')) return "tab";
      if (role === "listitem" || tag === "li") return "list_item";
      if (role === "switch") return "switch";
      if (role === "slider") return "slider";
      return "button";
    }

    function getActions(elementType) {
      switch (elementType) {
        case "text_field": return ["tap", "enter_text"];
        case "slider": return ["tap", "swipe"];
        default: return ["tap", "long_press"];
      }
    }

    function getValue(el, elementType) {
      switch (elementType) {
        case "text_field": return el.value || "";
        case "checkbox":
        case "switch": return el.checked || false;
        case "dropdown": return el.value || "";
        case "slider": return parseFloat(el.value) || 0;
        default: return undefined;
      }
    }

    var selectors = "button, a, input, textarea, select, [role=button], [role=link], " +
      "[role=textbox], [role=checkbox], [role=radio], [role=tab], [role=switch], " +
      "[role=slider], [onclick], li[onclick]";
    var nodes = document.querySelectorAll(selectors);

    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.offsetParent !== null || el.tagName === "INPUT") { // visible or input
        var elementType = getElementType(el);
        var refId = generateSemanticRefId(el, elementType);
        var rect = el.getBoundingClientRect();

        var element = {
          ref: refId,
          type: el.tagName + (el.type ? "[" + el.type + "]" : ""),
          text: (el.textContent || el.value || "").trim().substring(0, 100) || null,
          actions: getActions(elementType),
          enabled: !el.disabled && !el.readOnly,
          bounds: {
            x: Math.round(rect.x),
            y: Math.round(rect.y),
            w: Math.round(rect.width),
            h: Math.round(rect.height)
          }
        };

        var label = el.getAttribute("aria-label") || el.getAttribute("placeholder") || el.getAttribute("title");
        if (label) element.label = label;

        var value = getValue(el, elementType);
        if (value !== undefined) element.value = value;

        elements.push(element);
      }
    }

    // Generate summary
    var summaryParts = Object.keys(refCounts).map(function(prefix) {
      var count = refCounts[prefix];
      var label = {
        btn: "button", tf: "text field", sw: "switch", sl: "slider",
        dd: "dropdown", item: "list item", lnk: "link", tab: "tab"
      }[prefix] || "element";
      return count + " " + label + (count === 1 ? "" : (label === "switch" ? "es" : "s"));
    });

    var summary = summaryParts.length === 0 ? 
      "No interactive elements found" :
      elements.length + " interactive: " + summaryParts.join(", ");

    return { elements: elements, summary: summary };
  };

  methods.tap = function (params) {
    var el = findElement(params);
    if (!el) return { success: false, message: "Element not found" };
    el.click();
    return { success: true, message: "Tapped" };
  };

  methods.enter_text = function (params) {
    var el = findElement({ 
      key: params.key, 
      selector: params.selector,
      ref: params.ref 
    });
    if (!el) return { success: false, message: "Element not found" };
    // Focus and set value — pick the correct prototype for React/Vue change detection
    el.focus();
    var proto =
      el.tagName === "TEXTAREA"
        ? window.HTMLTextAreaElement.prototype
        : window.HTMLInputElement.prototype;
    var nativeSetter = Object.getOwnPropertyDescriptor(proto, "value");
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

  methods.go_back = function () {
    window.history.back();
    return { success: true, message: "Navigated back via history.back()" };
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
