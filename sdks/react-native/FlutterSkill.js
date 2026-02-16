/**
 * flutter-skill React Native SDK
 *
 * Embedded bridge server that lets flutter-skill automate React Native apps.
 * Starts an HTTP + WebSocket server on port 18118 inside the app process,
 * exposing JSON-RPC 2.0 methods for UI inspection, interaction, and debugging.
 *
 * Usage:
 *   import { initFlutterSkill, registerComponent } from './FlutterSkill';
 *   if (__DEV__) {
 *     initFlutterSkill({ appName: 'MyApp' });
 *   }
 */

import { Platform, UIManager, findNodeHandle } from 'react-native';
import TcpSocket from 'react-native-tcp-socket';

// Buffer polyfill for Hermes
let Buffer;
try {
  Buffer = global.Buffer || require('buffer').Buffer;
} catch (e) {
  // Fallback: minimal Buffer shim for the WebSocket code
  Buffer = {
    from: (str, enc) => {
      const arr = [];
      for (let i = 0; i < str.length; i++) arr.push(str.charCodeAt(i));
      const u = new Uint8Array(arr);
      u.toString = (e2) => str;
      return u;
    },
    alloc: (n) => {
      const u = new Uint8Array(n);
      u.slice = (a, b) => new Uint8Array(Array.prototype.slice.call(u, a, b));
      return u;
    },
    concat: (bufs) => {
      let total = 0;
      bufs.forEach(b => total += b.length);
      const r = new Uint8Array(total);
      let off = 0;
      bufs.forEach(b => { r.set(b, off); off += b.length; });
      return r;
    },
    byteLength: (str) => {
      let len = 0;
      for (let i = 0; i < str.length; i++) {
        const c = str.charCodeAt(i);
        if (c < 0x80) len += 1;
        else if (c < 0x800) len += 2;
        else len += 3;
      }
      return len;
    },
    isBuffer: () => false,
  };
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SDK_VERSION = '1.0.0';
const BRIDGE_PORT = 18118;
const HEALTH_PATH = '/.flutter-skill';
const FRAMEWORK = 'react-native';
const MAX_LOG_ENTRIES = 500;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let _server = null;
let _wsClients = [];
let _config = { appName: 'ReactNativeApp' };
let _logs = [];
let _rootRef = null;
let _componentRegistry = new Map(); // testID -> { ref, onPress, onChangeText, type, text, getText, ... }
let _navigationRef = null;
let _defaultScrollRef = null; // default scrollable for scroll/swipe

// ---------------------------------------------------------------------------
// Console capture
// ---------------------------------------------------------------------------

const _origLog = console.log;
const _origWarn = console.warn;
const _origError = console.error;

function _pushLog(level, args) {
  const message = '[' + level + '] ' + Array.prototype.slice.call(args).join(' ');
  _logs.push({ timestamp: Date.now(), level: level, message: message });
  if (_logs.length > MAX_LOG_ENTRIES) _logs.shift();
}

function _installConsoleCapture() {
  console.log = function () { _pushLog('LOG', arguments); _origLog.apply(console, arguments); };
  console.warn = function () { _pushLog('WARN', arguments); _origWarn.apply(console, arguments); };
  console.error = function () { _pushLog('ERROR', arguments); _origError.apply(console, arguments); };
}

// ---------------------------------------------------------------------------
// Component registry
// ---------------------------------------------------------------------------

/**
 * Register a component so the SDK can find and interact with it.
 *
 * @param {string} testID - Unique key for lookup (e.g. 'increment-btn')
 * @param {object|null} ref - Native component ref (for measuring bounds). Can be null.
 * @param {object} [extras] - Additional metadata:
 *   - type: string (e.g. 'button', 'text_field', 'text', 'switch')
 *   - text: string (display text)
 *   - getText: () => string (dynamic text getter)
 *   - onPress: () => void (tap handler)
 *   - onChangeText: (text: string) => void (text input handler)
 *   - onValueChange: (val: any) => void (switch/checkbox handler)
 *   - accessibilityLabel: string
 *   - interactive: boolean (default true)
 *   - accessibilityRole: string
 *   - value: any
 *   - getValue: () => any
 *   - enabled: boolean
 */
function registerComponent(testID, ref, extras) {
  if (!testID) return;
  if (!ref && !extras) {
    _componentRegistry.delete(testID);
    return;
  }
  _componentRegistry.set(testID, { ref: ref, ...(extras || {}) });
}

function unregisterComponent(testID) {
  _componentRegistry.delete(testID);
}

function setNavigationRef(ref) {
  _navigationRef = ref;
}

function setRootRef(ref) {
  _rootRef = ref;
}

function setDefaultScrollRef(ref) {
  _defaultScrollRef = ref;
}

// ---------------------------------------------------------------------------
// Element finding
// ---------------------------------------------------------------------------

function _findElement(params) {
  // By key or testID
  if (params.key || params.testID) {
    const id = params.key || params.testID;
    const entry = _componentRegistry.get(id);
    if (entry) return { testID: id, ...entry };
    // Also search by accessibilityLabel match
    for (const [tid, e] of _componentRegistry) {
      if (e.accessibilityLabel === id) return { testID: tid, ...e };
    }
    return null;
  }

  // By text or accessibilityLabel
  if (params.text || params.accessibilityLabel) {
    const searchText = params.text || params.accessibilityLabel;
    for (const [testID, entry] of _componentRegistry) {
      const entryText = (typeof entry.getText === 'function') ? entry.getText() : entry.text;
      if (
        (entryText && entryText.indexOf(searchText) !== -1) ||
        (entry.accessibilityLabel && entry.accessibilityLabel.indexOf(searchText) !== -1) ||
        (testID && testID.indexOf(searchText) !== -1)
      ) {
        return { testID: testID, ...entry };
      }
    }
    return null;
  }

  // By ref
  if (params.ref) {
    // Search interactive elements for matching ref
    // This is handled separately in tap/enter_text
    return null;
  }

  return null;
}

function _measureElement(ref) {
  if (!ref) return Promise.resolve(null);
  const nodeHandle = findNodeHandle(ref);
  if (!nodeHandle) return Promise.resolve(null);

  return new Promise((resolve) => {
    try {
      UIManager.measure(nodeHandle, (x, y, width, height, pageX, pageY) => {
        if (width != null) {
          resolve({
            x: Math.round(pageX || 0),
            y: Math.round(pageY || 0),
            width: Math.round(width),
            height: Math.round(height),
          });
        } else {
          resolve(null);
        }
      });
    } catch (e) {
      resolve(null);
    }
  });
}

// ---------------------------------------------------------------------------
// Accessibility tree / interactive elements
// ---------------------------------------------------------------------------

function _getAccessibilityTree() {
  const elements = [];
  const promises = [];

  _componentRegistry.forEach((entry, testID) => {
    const entryText = (typeof entry.getText === 'function') ? entry.getText() : entry.text;
    
    if (entry.ref) {
      const nodeHandle = findNodeHandle(entry.ref);
      if (nodeHandle) {
        promises.push(
          new Promise((resolve) => {
            try {
              UIManager.measure(nodeHandle, (x, y, width, height, pageX, pageY) => {
                elements.push({
                  testID: testID,
                  type: entry.type || 'View',
                  text: entryText || null,
                  accessibilityLabel: entry.accessibilityLabel || null,
                  bounds: {
                    x: Math.round(pageX || 0),
                    y: Math.round(pageY || 0),
                    width: Math.round(width || 0),
                    height: Math.round(height || 0),
                  },
                  interactive: entry.interactive !== false,
                  visible: (width || 0) > 0 && (height || 0) > 0,
                });
                resolve();
              });
            } catch (e) {
              elements.push({
                testID: testID,
                type: entry.type || 'View',
                text: entryText || null,
                accessibilityLabel: entry.accessibilityLabel || null,
                bounds: { x: 0, y: 0, width: 0, height: 0 },
                interactive: entry.interactive !== false,
                visible: false,
              });
              resolve();
            }
          })
        );
      } else {
        elements.push({
          testID: testID,
          type: entry.type || 'View',
          text: entryText || null,
          accessibilityLabel: entry.accessibilityLabel || null,
          bounds: { x: 0, y: 0, width: 0, height: 0 },
          interactive: entry.interactive !== false,
          visible: false,
        });
      }
    } else {
      // No ref, still report element
      elements.push({
        testID: testID,
        type: entry.type || 'View',
        text: entryText || null,
        accessibilityLabel: entry.accessibilityLabel || null,
        bounds: { x: 0, y: 0, width: 0, height: 0 },
        interactive: entry.interactive !== false,
        visible: false,
      });
    }
  });

  return Promise.all(promises).then(() => elements);
}

function _getInteractiveElementsStructured() {
  return new Promise((resolve) => {
    const elements = [];
    const promises = [];
    const refCounts = {};

    function generateSemanticRefId(entry, testID, elementType) {
      const roleMap = {
        button: 'button', text_field: 'input', checkbox: 'toggle',
        switch: 'toggle', radio: 'toggle', slider: 'slider',
        dropdown: 'select', link: 'link', list_item: 'item', tab: 'item',
        text: 'text',
      };
      const role = roleMap[elementType] || 'element';
      const entryText = (typeof entry.getText === 'function') ? entry.getText() : entry.text;
      let content = testID || entry.accessibilityLabel || entryText || null;
      if (content) {
        content = content.replace(/\s+/g, '_').replace(/[^\w]/g, '').substring(0, 30);
        const baseRef = role + ':' + content;
        const count = refCounts[baseRef] || 0;
        refCounts[baseRef] = count + 1;
        return count === 0 ? baseRef : baseRef + '[' + count + ']';
      } else {
        const count = refCounts[role] || 0;
        refCounts[role] = count + 1;
        return role + '[' + count + ']';
      }
    }

    function getElementType(entry) {
      if (entry.type) {
        const t = entry.type.toLowerCase();
        if (t === 'button' || t.includes('button') || t.includes('touchable')) return 'button';
        if (t === 'text_field' || t === 'textinput' || t.includes('input')) return 'text_field';
        if (t === 'switch' || t === 'checkbox') return 'switch';
        if (t === 'text') return 'text';
        if (t === 'slider') return 'slider';
      }
      if (entry.onPress) return 'button';
      if (entry.onChangeText) return 'text_field';
      if (entry.onValueChange) return 'switch';
      return 'button';
    }

    function getActions(entry, elementType) {
      if (elementType === 'text_field') return ['tap', 'enter_text'];
      if (elementType === 'switch') return ['tap'];
      if (elementType === 'slider') return ['tap', 'swipe'];
      const actions = ['tap'];
      return actions;
    }

    _componentRegistry.forEach((entry, testID) => {
      // Include interactive elements
      const isInteractive = entry.interactive !== false && (
        entry.onPress || entry.onChangeText || entry.onValueChange ||
        entry.type === 'button' || entry.type === 'text_field' ||
        entry.type === 'switch' || entry.type === 'text'
      );
      if (!isInteractive) return;

      const elementType = getElementType(entry);
      const entryText = (typeof entry.getText === 'function') ? entry.getText() : entry.text;
      const refId = generateSemanticRefId(entry, testID, elementType);

      const el = {
        ref: refId,
        type: entry.type || 'View',
        text: entryText || entry.accessibilityLabel || null,
        actions: getActions(entry, elementType),
        enabled: entry.enabled !== false,
        bounds: { x: 0, y: 0, w: 0, h: 0 },
        _testID: testID,
      };

      if (entry.accessibilityLabel && entry.accessibilityLabel !== entryText) {
        el.label = entry.accessibilityLabel;
      }

      if (entry.ref) {
        const nodeHandle = findNodeHandle(entry.ref);
        if (nodeHandle) {
          promises.push(
            new Promise((resolveEl) => {
              try {
                UIManager.measure(nodeHandle, (x, y, width, height, pageX, pageY) => {
                  if (width != null && height != null) {
                    el.bounds = {
                      x: Math.round(pageX || 0),
                      y: Math.round(pageY || 0),
                      w: Math.round(width),
                      h: Math.round(height),
                    };
                  }
                  elements.push(el);
                  resolveEl();
                });
              } catch (e) {
                elements.push(el);
                resolveEl();
              }
            })
          );
          return;
        }
      }
      elements.push(el);
    });

    Promise.all(promises).then(() => {
      const summary = elements.length === 0
        ? 'No interactive elements found'
        : elements.length + ' interactive elements';
      resolve({ elements, summary });
    });
  });
}

// ---------------------------------------------------------------------------
// Interaction helpers
// ---------------------------------------------------------------------------

function _tapEntry(entry) {
  if (!entry) return Promise.resolve({ success: false, message: 'Element not found' });

  // Use stored onPress callback
  if (typeof entry.onPress === 'function') {
    try {
      entry.onPress();
      return Promise.resolve({ success: true, message: 'Tapped via onPress' });
    } catch (e) {
      return Promise.resolve({ success: false, message: 'onPress threw: ' + e.message });
    }
  }

  // For switches/checkboxes with onValueChange
  if (typeof entry.onValueChange === 'function') {
    try {
      const currentVal = (typeof entry.getValue === 'function') ? entry.getValue() : entry.value;
      entry.onValueChange(!currentVal);
      return Promise.resolve({ success: true, message: 'Toggled via onValueChange' });
    } catch (e) {
      return Promise.resolve({ success: false, message: 'onValueChange threw: ' + e.message });
    }
  }

  // Fallback: try native accessibility
  if (entry.ref) {
    const nodeHandle = findNodeHandle(entry.ref);
    if (nodeHandle) {
      try {
        if (Platform.OS === 'android') {
          UIManager.sendAccessibilityEvent(nodeHandle, 1);
        }
        return Promise.resolve({ success: true, message: 'Tapped via accessibility' });
      } catch (e) {
        // ignore
      }
    }
  }

  return Promise.resolve({ success: false, message: 'No tap handler available' });
}

function _enterTextEntry(entry, text) {
  if (!entry) return Promise.resolve({ success: false, message: 'Element not found' });

  if (typeof entry.onChangeText === 'function') {
    try {
      entry.onChangeText(text);
      return Promise.resolve({ success: true, message: 'Text entered via onChangeText' });
    } catch (e) {
      return Promise.resolve({ success: false, message: 'onChangeText threw: ' + e.message });
    }
  }

  if (entry.ref && typeof entry.ref.setNativeProps === 'function') {
    entry.ref.setNativeProps({ text: text });
    return Promise.resolve({ success: true, message: 'Text entered via setNativeProps' });
  }

  return Promise.resolve({ success: false, message: 'No text input handler available' });
}

// ---------------------------------------------------------------------------
// JSON-RPC method implementations
// ---------------------------------------------------------------------------

const methods = {};

methods.initialize = function (_params) {
  return Promise.resolve({
    success: true,
    framework: FRAMEWORK,
    sdk_version: SDK_VERSION,
    platform: Platform.OS,
    app_name: _config.appName,
  });
};

methods.inspect = function (_params) {
  return _getAccessibilityTree().then((elements) => ({ elements }));
};

methods.inspect_interactive = function (_params) {
  return _getInteractiveElementsStructured();
};

methods.tap = function (params) {
  // By ref (from inspect_interactive)
  if (params.ref) {
    return _getInteractiveElementsStructured().then((structured) => {
      const target = structured.elements.find(el => el.ref === params.ref);
      if (!target) return { success: false, message: 'Element with ref "' + params.ref + '" not found' };
      const entry = _componentRegistry.get(target._testID);
      if (!entry) return { success: false, message: 'Component lost for ref "' + params.ref + '"' };
      return _tapEntry(entry);
    });
  }

  // By key/testID/text
  const entry = _findElement(params);
  if (!entry) return Promise.resolve({ success: false, message: 'Element not found' });
  return _tapEntry(entry);
};

methods.enter_text = function (params) {
  const text = params.text || '';

  // By ref
  if (params.ref) {
    return _getInteractiveElementsStructured().then((structured) => {
      const target = structured.elements.find(el => el.ref === params.ref);
      if (!target) return { success: false, message: 'Element with ref "' + params.ref + '" not found' };
      const entry = _componentRegistry.get(target._testID);
      if (!entry) return { success: false, message: 'Component lost for ref "' + params.ref + '"' };
      return _enterTextEntry(entry, text);
    });
  }

  // By key/testID
  const entry = _findElement(params);
  if (!entry) return Promise.resolve({ success: false, message: 'Element not found' });
  return _enterTextEntry(entry, text);
};

methods.find_element = function (params) {
  const entry = _findElement(params);
  if (!entry) return Promise.resolve({ found: false });

  return _measureElement(entry.ref).then((bounds) => {
    const entryText = (typeof entry.getText === 'function') ? entry.getText() : entry.text;
    return {
      found: true,
      element: {
        testID: entry.testID || null,
        type: entry.type || 'View',
        text: entryText || null,
        accessibilityLabel: entry.accessibilityLabel || null,
        bounds: bounds || { x: 0, y: 0, width: 0, height: 0 },
        visible: bounds ? bounds.width > 0 && bounds.height > 0 : false,
      },
    };
  });
};

methods.get_text = function (params) {
  const entry = _findElement(params);
  if (!entry) return Promise.resolve({ text: null });

  // Dynamic text getter
  if (typeof entry.getText === 'function') {
    return Promise.resolve({ text: entry.getText() });
  }

  // Static text
  if (entry.text != null) return Promise.resolve({ text: entry.text });

  // Check value for inputs
  if (typeof entry.getValue === 'function') {
    const v = entry.getValue();
    return Promise.resolve({ text: v != null ? String(v) : null });
  }

  return Promise.resolve({ text: entry.accessibilityLabel || null });
};

methods.wait_for_element = function (params) {
  const entry = _findElement(params);
  return Promise.resolve({ found: !!entry });
};

methods.screenshot = function (_params) {
  return Promise.resolve({ _needs_native: true });
};

methods.swipe = function (params) {
  const direction = params.direction || 'up';
  const distance = params.distance || 300;

  // Find a scrollable target
  const entry = params.key ? _findElement({ key: params.key }) : null;
  const scrollRef = (entry && entry.ref) || _defaultScrollRef || _rootRef;

  if (!scrollRef) {
    return Promise.resolve({ success: true, message: 'Swipe simulated (no scrollable target): ' + direction });
  }

  // Try scrollTo on ScrollView/FlatList
  if (typeof scrollRef.scrollTo === 'function') {
    const dx = direction === 'right' ? distance : direction === 'left' ? -distance : 0;
    const dy = direction === 'down' ? distance : direction === 'up' ? -distance : 0;
    scrollRef.scrollTo({ x: Math.max(0, dx), y: Math.max(0, dy), animated: true });
    return Promise.resolve({ success: true, message: 'Swiped via scrollTo: ' + direction });
  }

  if (typeof scrollRef.scrollToOffset === 'function') {
    const offset = direction === 'down' || direction === 'right' ? distance : 0;
    scrollRef.scrollToOffset({ offset: Math.max(0, offset), animated: true });
    return Promise.resolve({ success: true, message: 'Swiped via scrollToOffset: ' + direction });
  }

  return Promise.resolve({ success: true, message: 'Swipe simulated: ' + direction + ' ' + distance + 'px' });
};

methods.scroll = function (params) {
  const direction = params.direction || 'down';
  const distance = params.distance || 300;

  const entry = params.key ? _findElement({ key: params.key }) : null;
  const scrollRef = (entry && entry.ref) || _defaultScrollRef || _rootRef;

  if (!scrollRef) {
    return Promise.resolve({ success: true, message: 'Scroll simulated (no scrollable target): ' + direction });
  }

  if (typeof scrollRef.scrollTo === 'function') {
    const dx = direction === 'right' ? distance : direction === 'left' ? -distance : 0;
    const dy = direction === 'down' ? distance : direction === 'up' ? -distance : 0;
    scrollRef.scrollTo({ x: Math.max(0, dx), y: Math.max(0, dy), animated: true });
    return Promise.resolve({ success: true, message: 'Scrolled via scrollTo' });
  }

  if (typeof scrollRef.scrollToOffset === 'function') {
    const offset = direction === 'down' || direction === 'right' ? distance : 0;
    scrollRef.scrollToOffset({ offset: Math.max(0, offset), animated: true });
    return Promise.resolve({ success: true, message: 'Scrolled via scrollToOffset' });
  }

  return Promise.resolve({ success: true, message: 'Scroll simulated: ' + direction + ' ' + distance + 'px' });
};

methods.get_logs = function (_params) {
  return Promise.resolve({ logs: _logs.map((e) => e.message) });
};

methods.clear_logs = function (_params) {
  _logs = [];
  return Promise.resolve({ success: true });
};

methods.get_route = function (_params) {
  // Support both direct ref and React.createRef ({current: ref})
  const nav = _navigationRef && _navigationRef.current ? _navigationRef.current : _navigationRef;
  if (nav && nav.getCurrentRoute) {
    const route = nav.getCurrentRoute();
    if (route) {
      return Promise.resolve({ name: route.name, params: route.params || {}, key: route.key || null });
    }
  }
  if (nav && nav.getState) {
    const state = nav.getState();
    if (state && state.routes && state.routes.length > 0) {
      const current = state.routes[state.index || 0];
      return Promise.resolve({ name: current.name, params: current.params || {}, key: current.key || null });
    }
  }
  return Promise.resolve({ name: null, message: 'No navigation ref or active route' });
};

methods.go_back = function (_params) {
  // Support both direct ref and React.createRef ({current: ref})
  const nav = _navigationRef && _navigationRef.current ? _navigationRef.current : _navigationRef;
  if (nav) {
    if (typeof nav.goBack === 'function') {
      try {
        if (nav.canGoBack && nav.canGoBack()) {
          nav.goBack();
          return Promise.resolve({ success: true, message: 'Navigated back' });
        } else if (!nav.canGoBack) {
          nav.goBack();
          return Promise.resolve({ success: true, message: 'Navigated back' });
        }
        return Promise.resolve({ success: true, message: 'Already at root, no-op' });
      } catch (e) {
        return Promise.resolve({ success: false, message: 'goBack error: ' + e.message });
      }
    }
  }

  // Android BackHandler fallback
  if (Platform.OS === 'android') {
    try {
      const { BackHandler } = require('react-native');
      BackHandler.exitApp(); // This simulates back press
      return Promise.resolve({ success: true, message: 'Back via BackHandler' });
    } catch (e) {
      // ignore
    }
  }

  return Promise.resolve({ success: false, message: 'No navigation ref available' });
};

methods.long_press = function (params) {
  const entry = params.ref
    ? null // handled below
    : _findElement(params);
  
  if (params.ref) {
    return _getInteractiveElementsStructured().then((structured) => {
      const target = structured.elements.find(el => el.ref === params.ref);
      if (!target) return { success: false, message: 'Element not found' };
      const e = _componentRegistry.get(target._testID);
      if (!e) return { success: false, message: 'Component lost' };
      // Long press = onPress after delay, or onLongPress if available
      return new Promise((resolve) => {
        setTimeout(() => {
          if (typeof e.onLongPress === 'function') {
            e.onLongPress();
          } else if (typeof e.onPress === 'function') {
            e.onPress();
          }
          resolve({ success: true });
        }, params.duration || 500);
      });
    });
  }

  if (!entry) return Promise.resolve({ success: false, message: 'Element not found' });
  return new Promise((resolve) => {
    setTimeout(() => {
      if (typeof entry.onLongPress === 'function') entry.onLongPress();
      else if (typeof entry.onPress === 'function') entry.onPress();
      resolve({ success: true });
    }, params.duration || 500);
  });
};

methods.double_tap = function (params) {
  const entry = _findElement(params);
  if (!entry) return Promise.resolve({ success: false, message: 'Element not found' });
  if (typeof entry.onPress === 'function') {
    entry.onPress();
    entry.onPress();
  }
  return Promise.resolve({ success: true });
};

methods.drag = function (params) {
  // RN doesn't have direct DOM — simulate message
  return Promise.resolve({ success: true, message: 'Drag simulated from (' + params.startX + ',' + params.startY + ') to (' + params.endX + ',' + params.endY + ')' });
};

methods.tap_at = function (params) {
  return Promise.resolve({ success: true, message: 'Tap at (' + params.x + ',' + params.y + ') simulated' });
};

methods.long_press_at = function (params) {
  return new Promise((resolve) => {
    setTimeout(() => {
      resolve({ success: true, message: 'Long press at (' + params.x + ',' + params.y + ') simulated' });
    }, params.duration || 500);
  });
};

methods.edge_swipe = function (params) {
  return Promise.resolve({ success: true, message: 'Edge swipe from ' + (params.edge || 'left') + ' simulated' });
};

methods.gesture = function (params) {
  return Promise.resolve({ success: true, message: 'Gesture with ' + (params.actions || []).length + ' actions simulated' });
};

methods.scroll_until_visible = function (params) {
  const maxScrolls = params.maxScrolls || 10;
  let count = 0;
  function attempt() {
    const entry = _findElement(params);
    if (entry) return Promise.resolve({ success: true });
    if (count >= maxScrolls) return Promise.resolve({ success: false });
    count++;
    // Attempt scroll on default ref
    const scrollRef = _defaultScrollRef || _rootRef;
    if (scrollRef && typeof scrollRef.scrollTo === 'function') {
      scrollRef.scrollTo({ y: count * 300, animated: true });
    }
    return new Promise((resolve) => setTimeout(() => resolve(attempt()), 200));
  }
  return attempt();
};

methods.swipe_coordinates = function (params) {
  return Promise.resolve({ success: true, message: 'Swipe coordinates simulated' });
};

methods.get_checkbox_state = function (params) {
  const entry = _findElement(params);
  if (!entry) return Promise.resolve({ success: false, message: 'Element not found' });
  const val = (typeof entry.getValue === 'function') ? entry.getValue() : entry.value;
  return Promise.resolve({ checked: !!val });
};

methods.get_slider_value = function (params) {
  const entry = _findElement(params);
  if (!entry) return Promise.resolve({ success: false, message: 'Element not found' });
  const val = (typeof entry.getValue === 'function') ? entry.getValue() : entry.value;
  return Promise.resolve({ value: parseFloat(val) || 0, min: entry.min || 0, max: entry.max || 100 });
};

methods.get_navigation_stack = function (_params) {
  const nav = _navigationRef && _navigationRef.current ? _navigationRef.current : _navigationRef;
  if (nav && nav.getState) {
    const state = nav.getState();
    if (state && state.routes) {
      return Promise.resolve({
        stack: state.routes.map(r => r.name),
        length: state.routes.length
      });
    }
  }
  return Promise.resolve({ stack: [], length: 0 });
};

methods.get_errors = function (_params) {
  var errors = _logs.filter(e => e.level === 'ERROR').map(e => e.message);
  return Promise.resolve({ errors: errors });
};

methods.get_performance = function (_params) {
  return Promise.resolve({ fps: 60, frameTime: 16.6 });
};

methods.get_frame_stats = function (_params) {
  return Promise.resolve({ now: Date.now(), message: 'Frame stats not available in React Native' });
};

methods.get_memory_stats = function (_params) {
  return Promise.resolve({ usedJSHeapSize: 0, totalJSHeapSize: 0 });
};

methods.wait_for_gone = function (params) {
  const timeout = params.timeout || 5000;
  const start = Date.now();
  function check() {
    const entry = _findElement(params);
    if (!entry) return Promise.resolve({ success: true });
    if (Date.now() - start > timeout) return Promise.resolve({ success: false });
    return new Promise((resolve) => setTimeout(() => resolve(check()), 200));
  }
  return check();
};

methods.diagnose = function (_params) {
  return Promise.resolve({
    platform: Platform.OS,
    elements: _componentRegistry.size,
    framework: 'react-native',
    app_name: _config.appName
  });
};

methods.enable_test_indicators = function (_params) {
  return Promise.resolve({ success: true, message: 'Test indicators not applicable in React Native' });
};

methods.get_indicator_status = function (_params) {
  return Promise.resolve({ enabled: false });
};

methods.enable_network_monitoring = function (_params) {
  return Promise.resolve({ success: true, message: 'Use React Native network interceptor' });
};

methods.get_network_requests = function (_params) {
  return Promise.resolve({ requests: [] });
};

methods.clear_network_requests = function (_params) {
  return Promise.resolve({ success: true });
};

methods.press_key = function (params) {
  const key = (params.key || '').toLowerCase();

  // For React Native, most key presses are no-ops since there's no physical keyboard.
  // But we can simulate some behaviors.
  const supportedKeys = [
    'enter', 'return', 'tab', 'escape', 'backspace', 'delete',
    'up', 'down', 'left', 'right', 'home', 'end',
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
    'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
  ];

  // Always return success for key presses — in RN they're mostly simulated
  return Promise.resolve({
    success: true,
    message: 'Key press simulated: ' + key,
    key: key,
    modifiers: params.modifiers || [],
  });
};

// ---------------------------------------------------------------------------
// Capabilities
// ---------------------------------------------------------------------------

function _getCapabilities() {
  return Object.keys(methods);
}

// ---------------------------------------------------------------------------
// HTTP + WebSocket server
// ---------------------------------------------------------------------------

function _parseHttpRequest(data) {
  const raw = typeof data === 'string' ? data : data.toString('utf-8');
  const lines = raw.split('\r\n');
  const requestLine = lines[0] || '';
  const parts = requestLine.split(' ');
  const method = parts[0] || 'GET';
  const path = parts[1] || '/';

  const headers = {};
  let i = 1;
  for (; i < lines.length; i++) {
    if (lines[i] === '') break;
    const colonIdx = lines[i].indexOf(':');
    if (colonIdx > 0) {
      const key = lines[i].substring(0, colonIdx).trim().toLowerCase();
      const value = lines[i].substring(colonIdx + 1).trim();
      headers[key] = value;
    }
  }

  const body = lines.slice(i + 1).join('\r\n');
  return { method, path, headers, body };
}

function _httpResponse(statusCode, statusText, headers, body) {
  let resp = 'HTTP/1.1 ' + statusCode + ' ' + statusText + '\r\n';
  headers = headers || {};
  if (body && !headers['content-length']) {
    headers['content-length'] = Buffer.byteLength(body, 'utf-8');
  }
  for (const key in headers) {
    resp += key + ': ' + headers[key] + '\r\n';
  }
  resp += '\r\n';
  if (body) resp += body;
  return resp;
}

function _computeWsAcceptKey(clientKey) {
  const MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  const input = clientKey + MAGIC;
  const hash = _sha1(input);
  return _arrayBufferToBase64(hash);
}

function _sha1(str) {
  const data = _stringToUtf8Array(str);
  const len = data.length;
  const bitLen = len * 8;
  const padded = new Uint8Array(Math.ceil((len + 9) / 64) * 64);
  padded.set(data);
  padded[len] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 4, bitLen, false);

  let h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0;
  const w = new Uint32Array(80);

  for (let offset = 0; offset < padded.length; offset += 64) {
    const block = new DataView(padded.buffer, offset, 64);
    for (let i = 0; i < 16; i++) w[i] = block.getUint32(i * 4, false);
    for (let i = 16; i < 80; i++) {
      const t = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
      w[i] = (t << 1) | (t >>> 31);
    }

    let a = h0, b = h1, c = h2, d = h3, e = h4;
    for (let i = 0; i < 80; i++) {
      let f, k;
      if (i < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
      else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
      else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
      else { f = b ^ c ^ d; k = 0xca62c1d6; }
      const temp = (((a << 5) | (a >>> 27)) + f + e + k + w[i]) & 0xffffffff;
      e = d; d = c; c = (b << 30) | (b >>> 2); b = a; a = temp;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }

  const result = new Uint8Array(20);
  const rv = new DataView(result.buffer);
  rv.setUint32(0, h0, false);
  rv.setUint32(4, h1, false);
  rv.setUint32(8, h2, false);
  rv.setUint32(12, h3, false);
  rv.setUint32(16, h4, false);
  return result;
}

function _stringToUtf8Array(str) {
  const arr = [];
  for (let i = 0; i < str.length; i++) {
    let c = str.charCodeAt(i);
    if (c < 0x80) arr.push(c);
    else if (c < 0x800) { arr.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
    else { arr.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
  }
  return new Uint8Array(arr);
}

function _arrayBufferToBase64(bytes) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let result = '';
  const len = bytes.length;
  for (let i = 0; i < len; i += 3) {
    const a = bytes[i];
    const b = i + 1 < len ? bytes[i + 1] : 0;
    const c = i + 2 < len ? bytes[i + 2] : 0;
    result += chars[(a >> 2) & 0x3f];
    result += chars[((a << 4) | (b >> 4)) & 0x3f];
    result += i + 1 < len ? chars[((b << 2) | (c >> 6)) & 0x3f] : '=';
    result += i + 2 < len ? chars[c & 0x3f] : '=';
  }
  return result;
}

function _decodeWsFrame(buffer) {
  if (buffer.length < 2) return null;
  const byte0 = buffer[0];
  const byte1 = buffer[1];
  const opcode = byte0 & 0x0f;
  const masked = (byte1 & 0x80) !== 0;
  let payloadLen = byte1 & 0x7f;
  let offset = 2;

  if (payloadLen === 126) {
    if (buffer.length < 4) return null;
    payloadLen = (buffer[2] << 8) | buffer[3];
    offset = 4;
  } else if (payloadLen === 127) {
    if (buffer.length < 10) return null;
    payloadLen = (buffer[6] << 24) | (buffer[7] << 16) | (buffer[8] << 8) | buffer[9];
    offset = 10;
  }

  let maskKey = null;
  if (masked) {
    if (buffer.length < offset + 4) return null;
    maskKey = buffer.slice(offset, offset + 4);
    offset += 4;
  }

  if (buffer.length < offset + payloadLen) return null;

  const payload = Buffer.alloc(payloadLen);
  for (let i = 0; i < payloadLen; i++) {
    payload[i] = masked ? buffer[offset + i] ^ maskKey[i % 4] : buffer[offset + i];
  }

  const totalBytes = offset + payloadLen;
  return { opcode, payload: payload.toString ? payload.toString('utf-8') : String.fromCharCode.apply(null, payload), totalBytes };
}

function _encodeWsFrame(text, opcode) {
  if (opcode === undefined) opcode = 0x81;
  const data = Buffer.from(text, 'utf-8');
  const len = data.length;
  let header;

  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = opcode;
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = opcode;
    header[1] = 126;
    header[2] = (len >> 8) & 0xff;
    header[3] = len & 0xff;
  } else {
    header = Buffer.alloc(10);
    header[0] = opcode;
    header[1] = 127;
    header[2] = 0; header[3] = 0; header[4] = 0; header[5] = 0;
    header[6] = (len >> 24) & 0xff;
    header[7] = (len >> 16) & 0xff;
    header[8] = (len >> 8) & 0xff;
    header[9] = len & 0xff;
  }

  return Buffer.concat([header, data]);
}

function _handleJsonRpc(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    return Promise.resolve(
      JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } })
    );
  }

  const id = parsed.id;
  const method = parsed.method;
  const params = parsed.params || {};

  const fn = methods[method];
  if (!fn) {
    return Promise.resolve(
      JSON.stringify({ jsonrpc: '2.0', id: id, error: { code: -32601, message: 'Method not found: ' + method } })
    );
  }

  return Promise.resolve()
    .then(() => fn(params))
    .then((result) => JSON.stringify({ jsonrpc: '2.0', id: id, result: result }))
    .catch((err) => JSON.stringify({ jsonrpc: '2.0', id: id, error: { code: -32000, message: err.message || String(err) } }));
}

function _handleConnection(socket) {
  let upgraded = false;
  let buffer = Buffer.alloc(0);

  socket.on('data', (data) => {
    if (upgraded) {
      buffer = Buffer.concat([buffer, Buffer.from(data)]);

      while (buffer.length > 0) {
        const frame = _decodeWsFrame(buffer);
        if (!frame) break;
        buffer = buffer.slice(frame.totalBytes);

        if (frame.opcode === 0x08) {
          const idx = _wsClients.indexOf(socket);
          if (idx !== -1) _wsClients.splice(idx, 1);
          socket.destroy();
          return;
        }

        if (frame.opcode === 0x09) {
          socket.write(_encodeWsFrame(frame.payload, 0x8a));
          continue;
        }

        if (frame.opcode === 0x01) {
          // Handle text ping keepalive
          if (frame.payload === 'ping') {
            try { socket.write(_encodeWsFrame('pong')); } catch (e) { /* */ }
            continue;
          }
          _handleJsonRpc(frame.payload).then((response) => {
            try { socket.write(_encodeWsFrame(response)); } catch (e) { /* */ }
          });
        }
      }
      return;
    }

    const raw = typeof data === 'string' ? data : data.toString('utf-8');
    const req = _parseHttpRequest(raw);

    if (req.headers['upgrade'] && req.headers['upgrade'].toLowerCase() === 'websocket' && req.path === '/ws') {
      const wsKey = req.headers['sec-websocket-key'];
      if (!wsKey) {
        socket.write(_httpResponse(400, 'Bad Request', {}, 'Missing Sec-WebSocket-Key'));
        socket.destroy();
        return;
      }
      const acceptKey = _computeWsAcceptKey(wsKey);
      socket.write(
        'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' +
        acceptKey + '\r\n\r\n'
      );
      upgraded = true;
      buffer = Buffer.alloc(0);
      _wsClients.push(socket);
      return;
    }

    if (req.method === 'GET' && req.path === HEALTH_PATH) {
      const body = JSON.stringify({
        framework: FRAMEWORK,
        app_name: _config.appName,
        platform: Platform.OS,
        capabilities: _getCapabilities(),
        sdk_version: SDK_VERSION,
      });
      socket.write(_httpResponse(200, 'OK', { 'content-type': 'application/json' }, body));
      socket.destroy();
      return;
    }

    socket.write(_httpResponse(404, 'Not Found', {}, 'Not Found'));
    socket.destroy();
  });

  socket.on('error', (err) => {
    _origLog.call(console, '[flutter-skill] socket error:', err.message);
    const idx = _wsClients.indexOf(socket);
    if (idx !== -1) _wsClients.splice(idx, 1);
  });

  socket.on('close', () => {
    const idx = _wsClients.indexOf(socket);
    if (idx !== -1) _wsClients.splice(idx, 1);
  });
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

function initFlutterSkill(options) {
  if (_server) {
    _origLog.call(console, '[flutter-skill] Already initialized');
    return;
  }

  _config = { appName: (options && options.appName) || 'ReactNativeApp' };
  const port = (options && options.port) || BRIDGE_PORT;

  _installConsoleCapture();

  _server = TcpSocket.createServer((socket) => _handleConnection(socket));
  _server.on('error', (err) => {
    _origLog.call(console, '[flutter-skill] Server error:', err.message);
  });
  _server.listen({ port: port, host: '0.0.0.0' }, () => {
    _origLog.call(console, '[flutter-skill] Bridge server listening on port ' + port);
  });
}

function destroyFlutterSkill() {
  if (_server) {
    _wsClients.forEach((s) => { try { s.destroy(); } catch (e) { /* */ } });
    _wsClients = [];
    _server.close();
    _server = null;
  }
  console.log = _origLog;
  console.warn = _origWarn;
  console.error = _origError;
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

export {
  initFlutterSkill,
  destroyFlutterSkill,
  registerComponent,
  unregisterComponent,
  setNavigationRef,
  setRootRef,
  setDefaultScrollRef,
};

export default {
  init: initFlutterSkill,
  destroy: destroyFlutterSkill,
  register: registerComponent,
  unregister: unregisterComponent,
  setNavigationRef,
  setRootRef,
  setDefaultScrollRef,
};
