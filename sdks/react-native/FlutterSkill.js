/**
 * flutter-skill React Native SDK
 *
 * Embedded bridge server that lets flutter-skill automate React Native apps.
 * Starts an HTTP + WebSocket server on port 18118 inside the app process,
 * exposing JSON-RPC 2.0 methods for UI inspection, interaction, and debugging.
 *
 * Usage:
 *   import { initFlutterSkill } from 'flutter-skill-react-native';
 *   // Call once in your app entry point (e.g. App.js)
 *   if (__DEV__) {
 *     initFlutterSkill({ appName: 'MyApp' });
 *   }
 *
 * Requires peer dependency: react-native-tcp-socket
 */

import { Platform, UIManager, findNodeHandle } from 'react-native';
import TcpSocket from 'react-native-tcp-socket';

// ---------------------------------------------------------------------------
// Constants (must match bridge_protocol.dart)
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
let _componentRegistry = new Map(); // testID -> { ref, component }
let _navigationRef = null; // React Navigation ref

// ---------------------------------------------------------------------------
// Console capture
// ---------------------------------------------------------------------------

const _origLog = console.log;
const _origWarn = console.warn;
const _origError = console.error;

function _pushLog(level, args) {
  const message = '[' + level + '] ' + Array.prototype.slice.call(args).join(' ');
  _logs.push({ timestamp: Date.now(), level: level, message: message });
  if (_logs.length > MAX_LOG_ENTRIES) {
    _logs.shift();
  }
}

function _installConsoleCapture() {
  console.log = function () {
    _pushLog('LOG', arguments);
    _origLog.apply(console, arguments);
  };
  console.warn = function () {
    _pushLog('WARN', arguments);
    _origWarn.apply(console, arguments);
  };
  console.error = function () {
    _pushLog('ERROR', arguments);
    _origError.apply(console, arguments);
  };
}

// ---------------------------------------------------------------------------
// Component registry (for element lookup by testID)
// ---------------------------------------------------------------------------

/**
 * Register a component ref so the SDK can find it by testID.
 * Call this from your components:
 *   <View testID="login_button" ref={ref => FlutterSkill.register('login_button', ref)} />
 *
 * Or use the withFlutterSkill HOC which does this automatically.
 */
function registerComponent(testID, ref, extras) {
  if (!testID) return;
  if (!ref) {
    _componentRegistry.delete(testID);
    return;
  }
  _componentRegistry.set(testID, { ref: ref, ...(extras || {}) });
}

function unregisterComponent(testID) {
  _componentRegistry.delete(testID);
}

/**
 * Set the React Navigation ref for route detection.
 *   const navigationRef = useNavigationContainerRef();
 *   FlutterSkill.setNavigationRef(navigationRef);
 */
function setNavigationRef(ref) {
  _navigationRef = ref;
}

/**
 * Set the root component ref for tree walking.
 */
function setRootRef(ref) {
  _rootRef = ref;
}

// ---------------------------------------------------------------------------
// Element finding
// ---------------------------------------------------------------------------

/**
 * Walk the UIManager accessibility tree and collect interactive elements.
 * This uses the native accessibility info available on both architectures.
 */
function _getAccessibilityTree() {
  // Collect all registered components with their layout info
  const elements = [];
  const promises = [];

  _componentRegistry.forEach((entry, testID) => {
    const ref = entry.ref;
    if (!ref) return;

    const nodeHandle = findNodeHandle(ref);
    if (!nodeHandle) return;

    promises.push(
      new Promise((resolve) => {
        UIManager.measure(nodeHandle, (x, y, width, height, pageX, pageY) => {
          if (width != null && height != null) {
            elements.push({
              testID: testID,
              type: entry.type || 'View',
              text: entry.text || null,
              accessibilityLabel: entry.accessibilityLabel || null,
              bounds: {
                x: Math.round(pageX || 0),
                y: Math.round(pageY || 0),
                width: Math.round(width),
                height: Math.round(height),
              },
              interactive: entry.interactive !== false,
              visible: width > 0 && height > 0,
            });
          }
          resolve();
        });
      })
    );
  });

  return Promise.all(promises).then(() => elements);
}

/**
 * Get interactive elements with ref ID system for React Native
 */
function _getInteractiveElementsStructured() {
  return new Promise((resolve) => {
    const elements = [];
    const promises = [];
    const refCounts = {};

    function generateSemanticRefId(entry, elementType) {
      // Map element types to semantic roles
      const roleMap = {
        button: 'button',
        text_field: 'input',
        checkbox: 'toggle',
        switch: 'toggle',
        radio: 'toggle',
        slider: 'slider',
        dropdown: 'select',
        link: 'link',
        list_item: 'item',
        tab: 'item'
      };

      const role = roleMap[elementType] || 'element';

      // Extract content with priority: testID > accessibilityLabel > text > fallback
      let content = entry.testID ||
                   entry.accessibilityLabel ||
                   entry.text ||
                   null;

      if (content) {
        // Clean and format content
        content = content.replace(/\s+/g, '_')
                        .replace(/[^\w]/g, '')
                        .substring(0, 30);
        if (content.length > 27) {
          content = content.substring(0, 27) + '...';
        }

        const baseRef = role + ':' + content;
        const count = refCounts[baseRef] || 0;
        refCounts[baseRef] = count + 1;

        return count === 0 ? baseRef : baseRef + '[' + count + ']';
      } else {
        // No content - use role + index fallback
        const count = refCounts[role] || 0;
        refCounts[role] = count + 1;
        return role + '[' + count + ']';
      }
    }

    function getElementType(entry) {
      const accessibilityRole = entry.accessibilityRole;
      const type = entry.type || 'View';

      if (accessibilityRole === 'button' || type.includes('Button')) return 'button';
      if (accessibilityRole === 'search' || type.includes('TextInput')) return 'text_field';
      if (accessibilityRole === 'switch') return 'switch';
      if (accessibilityRole === 'checkbox') return 'checkbox';
      if (accessibilityRole === 'radio') return 'radio';
      if (accessibilityRole === 'adjustable' || type.includes('Slider')) return 'slider';
      if (accessibilityRole === 'tab') return 'tab';
      if (accessibilityRole === 'link') return 'link';
      if (type.includes('TouchableOpacity') || type.includes('Touchable')) return 'button';
      if (type.includes('Picker')) return 'dropdown';

      // Check for interactive properties
      if (entry.onPress || entry.onLongPress) return 'button';
      
      return 'button'; // Default for interactive elements
    }

    function getActions(entry, elementType) {
      const actions = [];
      
      if (elementType === 'text_field') {
        actions.push('tap', 'enter_text');
      } else if (elementType === 'slider') {
        actions.push('tap', 'swipe');
      } else {
        actions.push('tap');
        if (entry.onLongPress) {
          actions.push('long_press');
        }
      }
      
      return actions;
    }

    function getValue(entry, elementType) {
      if (elementType === 'text_field') {
        return entry.value || '';
      } else if (elementType === 'switch' || elementType === 'checkbox') {
        return entry.selected || entry.checked || false;
      } else if (elementType === 'slider') {
        return entry.value || 0;
      }
      return undefined;
    }

    _componentRegistry.forEach((entry, testID) => {
      const ref = entry.ref;
      if (!ref) return;

      // Check if element is interactive
      const hasInteractiveRole = ['button', 'link', 'switch', 'checkbox', 'radio', 'search', 'adjustable', 'tab'].includes(entry.accessibilityRole);
      const hasInteractiveCallback = entry.onPress || entry.onLongPress || entry.interactive !== false;
      const isTextInput = entry.type && (entry.type.includes('TextInput') || entry.accessibilityRole === 'search');

      if (!hasInteractiveRole && !hasInteractiveCallback && !isTextInput) return;

      const nodeHandle = findNodeHandle(ref);
      if (!nodeHandle) return;

      promises.push(
        new Promise((resolveElement) => {
          UIManager.measure(nodeHandle, (x, y, width, height, pageX, pageY) => {
            if (width != null && height != null && width > 0 && height > 0) {
              const elementType = getElementType(entry);
              const refId = generateSemanticRefId(entry, elementType);

              const element = {
                ref: refId,
                type: entry.type || 'View',
                text: entry.text || entry.accessibilityLabel || null,
                actions: getActions(entry, elementType),
                enabled: entry.enabled !== false,
                bounds: {
                  x: Math.round(pageX || 0),
                  y: Math.round(pageY || 0),
                  w: Math.round(width),
                  h: Math.round(height),
                }
              };

              // Add optional fields
              if (entry.accessibilityLabel && entry.accessibilityLabel !== entry.text) {
                element.label = entry.accessibilityLabel;
              }
              
              const value = getValue(entry, elementType);
              if (value !== undefined) {
                element.value = value;
              }

              // Store original testID for internal use
              element._testID = testID;
              
              elements.push(element);
            }
            resolveElement();
          });
        })
      );
    });

    Promise.all(promises).then(() => {
      // Generate summary
      const counts = Object.entries(refCounts);
      const summaryParts = counts.map(([prefix, count]) => {
        switch (prefix) {
          case 'btn': return count + ' button' + (count === 1 ? '' : 's');
          case 'tf': return count + ' text field' + (count === 1 ? '' : 's');
          case 'sw': return count + ' switch' + (count === 1 ? '' : 'es');
          case 'sl': return count + ' slider' + (count === 1 ? '' : 's');
          case 'dd': return count + ' dropdown' + (count === 1 ? '' : 's');
          case 'item': return count + ' list item' + (count === 1 ? '' : 's');
          case 'lnk': return count + ' link' + (count === 1 ? '' : 's');
          case 'tab': return count + ' tab' + (count === 1 ? '' : 's');
          default: return count + ' element' + (count === 1 ? '' : 's');
        }
      });

      const summary = summaryParts.length === 0 ? 
        'No interactive elements found' : 
        elements.length + ' interactive: ' + summaryParts.join(', ');

      resolve({ elements, summary });
    });
  });
}

/**
 * Find a single element by testID, text, or accessibilityLabel.
 */
function _findElement(params) {
  if (params.key || params.testID) {
    const id = params.key || params.testID;
    const entry = _componentRegistry.get(id);
    if (entry && entry.ref) return { testID: id, ...entry };
    return null;
  }

  if (params.text || params.accessibilityLabel) {
    const searchText = params.text || params.accessibilityLabel;
    for (const [testID, entry] of _componentRegistry) {
      if (
        (entry.text && entry.text.indexOf(searchText) !== -1) ||
        (entry.accessibilityLabel &&
          entry.accessibilityLabel.indexOf(searchText) !== -1)
      ) {
        return { testID: testID, ...entry };
      }
    }
    return null;
  }

  return null;
}

/**
 * Get a node handle and measure it, returning bounds or null.
 */
function _measureElement(ref) {
  const nodeHandle = findNodeHandle(ref);
  if (!nodeHandle) return Promise.resolve(null);

  return new Promise((resolve) => {
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
  });
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
  return _getAccessibilityTree().then((elements) => {
    return { elements: elements };
  });
};

methods.inspect_interactive = function (_params) {
  return _getInteractiveElementsStructured().then((result) => {
    return result;
  });
};

methods.tap = function (params) {
  // Support ref parameter
  if (params.ref) {
    return _getInteractiveElementsStructured().then((structured) => {
      const targetElement = structured.elements.find(el => el.ref === params.ref);
      if (!targetElement) {
        return { success: false, message: 'Element with ref "' + params.ref + '" not found' };
      }
      
      // Find the original component by testID
      const testID = targetElement._testID;
      const entry = _componentRegistry.get(testID);
      if (!entry || !entry.ref) {
        return { success: false, message: 'Component reference lost for ref "' + params.ref + '"' };
      }
      
      return _tapComponent(entry.ref, 'ref');
    });
  }

  // Original logic for key/testID/text
  const entry = _findElement(params);
  if (!entry || !entry.ref) {
    return Promise.resolve({ success: false, message: 'Element not found' });
  }

  return _tapComponent(entry.ref, 'key');
};

function _tapComponent(component, method) {
  // Try calling onPress / onPressIn / props.onPress
  if (component.props && typeof component.props.onPress === 'function') {
    component.props.onPress();
    return Promise.resolve({ success: true, message: 'Tapped via onPress', method: method });
  }

  // Fallback: dispatch accessibility tap action
  const nodeHandle = findNodeHandle(component);
  if (nodeHandle) {
    UIManager.dispatchViewManagerCommand(nodeHandle, 'focus', []);
    // Simulate press via accessibility
    if (Platform.OS === 'android') {
      UIManager.sendAccessibilityEvent(nodeHandle, 1); // TYPE_VIEW_CLICKED
    }
    return Promise.resolve({
      success: true,
      message: 'Tapped via accessibility action',
      method: method,
    });
  }

  return Promise.resolve({
    success: false,
    message: 'Could not trigger tap on element',
  });
}

methods.enter_text = function (params) {
  const text = params.text || '';

  // Support ref parameter
  if (params.ref) {
    return _getInteractiveElementsStructured().then((structured) => {
      const targetElement = structured.elements.find(el => el.ref === params.ref);
      if (!targetElement) {
        return { success: false, message: 'Element with ref "' + params.ref + '" not found' };
      }
      
      // Find the original component by testID
      const testID = targetElement._testID;
      const entry = _componentRegistry.get(testID);
      if (!entry || !entry.ref) {
        return { success: false, message: 'Component reference lost for ref "' + params.ref + '"' };
      }
      
      return _enterTextIntoComponent(entry.ref, text, 'ref');
    });
  }

  // Original logic for key/testID
  const entry = _findElement({ key: params.key, testID: params.testID });
  if (!entry || !entry.ref) {
    return Promise.resolve({ success: false, message: 'Element not found' });
  }

  return _enterTextIntoComponent(entry.ref, text, 'key');
};

function _enterTextIntoComponent(component, text, method) {
  // TextInput components: call onChangeText or set nativeProps
  if (component.props && typeof component.props.onChangeText === 'function') {
    component.props.onChangeText(text);
    return Promise.resolve({ success: true, message: 'Text entered via onChangeText', method: method });
  }

  // Try setNativeProps for uncontrolled TextInput
  if (typeof component.setNativeProps === 'function') {
    component.setNativeProps({ text: text });
    return Promise.resolve({ success: true, message: 'Text entered via setNativeProps', method: method });
  }

  return Promise.resolve({
    success: false,
    message: 'Could not enter text: no onChangeText or setNativeProps available',
  });
}

methods.swipe = function (params) {
  const direction = params.direction || 'up';
  const distance = params.distance || 300;

  // Look for a target element or use the root
  const entry = params.key ? _findElement({ key: params.key }) : null;
  const ref = entry ? entry.ref : _rootRef;

  if (!ref) {
    return Promise.resolve({
      success: false,
      message: 'No target element or root ref available for swipe',
    });
  }

  const nodeHandle = findNodeHandle(ref);
  if (!nodeHandle) {
    return Promise.resolve({ success: false, message: 'Cannot resolve node handle' });
  }

  // Calculate gesture vectors
  return _measureElement(ref).then((bounds) => {
    if (!bounds) {
      return { success: false, message: 'Cannot measure target element' };
    }

    const cx = bounds.x + bounds.width / 2;
    const cy = bounds.y + bounds.height / 2;
    let endX = cx;
    let endY = cy;

    switch (direction) {
      case 'up':
        endY = cy - distance;
        break;
      case 'down':
        endY = cy + distance;
        break;
      case 'left':
        endX = cx - distance;
        break;
      case 'right':
        endX = cx + distance;
        break;
    }

    // Dispatch native scroll command as pan gesture approximation
    if (Platform.OS === 'android') {
      UIManager.dispatchViewManagerCommand(nodeHandle, 'scrollTo', [
        direction === 'left' || direction === 'right' ? endX - cx : 0,
        direction === 'up' || direction === 'down' ? endY - cy : 0,
        true,
      ]);
    } else {
      return {
        success: false,
        message: 'Swipe not supported on iOS via bridge. Use native driver for iOS swipe gestures.',
      };
    }

    return {
      success: true,
      message: 'Swipe dispatched: ' + direction + ' ' + distance + 'px',
      start: { x: cx, y: cy },
      end: { x: endX, y: endY },
    };
  });
};

methods.scroll = function (params) {
  const direction = params.direction || 'down';
  const distance = params.distance || 300;

  const entry = params.key ? _findElement({ key: params.key }) : null;
  const ref = entry ? entry.ref : _rootRef;

  if (!ref) {
    return Promise.resolve({
      success: false,
      message: 'No scrollable target or root ref',
    });
  }

  // If the registered component exposes scrollTo (ScrollView, FlatList)
  if (typeof ref.scrollTo === 'function') {
    const dx = direction === 'right' ? distance : direction === 'left' ? -distance : 0;
    const dy = direction === 'down' ? distance : direction === 'up' ? -distance : 0;
    ref.scrollTo({ x: dx, y: dy, animated: true });
    return Promise.resolve({ success: true, message: 'Scrolled via scrollTo' });
  }

  if (typeof ref.scrollToOffset === 'function') {
    const offset = direction === 'down' || direction === 'right' ? distance : -distance;
    ref.scrollToOffset({ offset: Math.max(0, offset), animated: true });
    return Promise.resolve({ success: true, message: 'Scrolled via scrollToOffset' });
  }

  return Promise.resolve({
    success: false,
    message: 'Target does not support scrollTo or scrollToOffset',
  });
};

methods.find_element = function (params) {
  const entry = _findElement(params);
  if (!entry || !entry.ref) {
    return Promise.resolve({ found: false });
  }

  return _measureElement(entry.ref).then((bounds) => {
    return {
      found: true,
      element: {
        testID: entry.testID || null,
        type: entry.type || 'View',
        text: entry.text || null,
        accessibilityLabel: entry.accessibilityLabel || null,
        bounds: bounds,
        visible: bounds ? bounds.width > 0 && bounds.height > 0 : false,
      },
    };
  });
};

methods.get_text = function (params) {
  const entry = _findElement(params);
  if (!entry) {
    return Promise.resolve({ text: null });
  }

  // For TextInput, try to read the current value
  if (entry.ref && entry.ref.props && entry.ref.props.value != null) {
    return Promise.resolve({ text: String(entry.ref.props.value) });
  }

  return Promise.resolve({ text: entry.text || null });
};

methods.wait_for_element = function (params) {
  // Synchronous check -- the proxy can poll
  const entry = _findElement(params);
  return Promise.resolve({ found: !!entry });
};

methods.screenshot = function (_params) {
  // React Native cannot capture screenshots from JS.
  // Signal to the proxy that native tooling is needed (xcrun simctl, adb screencap).
  return Promise.resolve({ _needs_native: true });
};

// ---------------------------------------------------------------------------
// Extended methods
// ---------------------------------------------------------------------------

methods.get_logs = function (_params) {
  return Promise.resolve({ logs: _logs.map((e) => e.message) });
};

methods.clear_logs = function (_params) {
  _logs = [];
  return Promise.resolve({ success: true });
};

methods.get_route = function (_params) {
  if (_navigationRef && _navigationRef.getCurrentRoute) {
    const route = _navigationRef.getCurrentRoute();
    if (route) {
      return Promise.resolve({
        name: route.name,
        params: route.params || {},
        key: route.key || null,
      });
    }
  }

  // Fallback: check if React Navigation state is available globally
  if (_navigationRef && _navigationRef.getState) {
    const state = _navigationRef.getState();
    if (state && state.routes && state.routes.length > 0) {
      const current = state.routes[state.index || 0];
      return Promise.resolve({
        name: current.name,
        params: current.params || {},
        key: current.key || null,
      });
    }
  }

  return Promise.resolve({ name: null, message: 'No navigation ref set or no active route' });
};

methods.go_back = function (_params) {
  if (_navigationRef && typeof _navigationRef.goBack === 'function') {
    _navigationRef.goBack();
    return Promise.resolve({ success: true, message: 'Navigated back' });
  }
  return Promise.resolve({ success: false, message: 'No navigation ref available' });
};

// ---------------------------------------------------------------------------
// Capabilities list (advertised in health check)
// ---------------------------------------------------------------------------

function _getCapabilities() {
  const caps = [
    'initialize',
    'inspect',
    'inspect_interactive',
    'tap',
    'enter_text',
    'swipe',
    'scroll',
    'find_element',
    'get_text',
    'wait_for_element',
    'screenshot',
    'get_logs',
    'clear_logs',
  ];
  if (_navigationRef) {
    caps.push('get_route', 'go_back');
  }
  return caps;
}

// ---------------------------------------------------------------------------
// HTTP + WebSocket server
// ---------------------------------------------------------------------------

/**
 * Parse a raw HTTP request buffer into { method, path, headers, body }.
 */
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
  return { method: method, path: path, headers: headers, body: body };
}

/**
 * Build a raw HTTP response string.
 */
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

/**
 * Compute the WebSocket accept key from Sec-WebSocket-Key.
 * Uses a basic SHA-1 implementation suitable for the handshake.
 */
function _computeWsAcceptKey(clientKey) {
  // We need SHA-1 + Base64. React Native includes a global `btoa` but
  // lacks a native crypto module. We use a tiny inline SHA-1.
  const MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  const input = clientKey + MAGIC;
  const hash = _sha1(input);
  return _arrayBufferToBase64(hash);
}

/**
 * Minimal SHA-1 (for WebSocket handshake only -- not for security).
 */
function _sha1(str) {
  const data = _stringToUtf8Array(str);
  const len = data.length;
  const bitLen = len * 8;

  // Pre-processing: add padding
  const padded = new Uint8Array(Math.ceil((len + 9) / 64) * 64);
  padded.set(data);
  padded[len] = 0x80;
  // Length in bits as big-endian 64-bit at end
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 4, bitLen, false);

  let h0 = 0x67452301;
  let h1 = 0xefcdab89;
  let h2 = 0x98badcfe;
  let h3 = 0x10325476;
  let h4 = 0xc3d2e1f0;
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
    else {
      arr.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
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

/**
 * Decode a WebSocket frame from raw buffer. Returns { opcode, payload } or null.
 */
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
    // 64-bit length -- skip high 4 bytes, read low 4
    if (buffer.length < 10) return null;
    payloadLen =
      (buffer[6] << 24) | (buffer[7] << 16) | (buffer[8] << 8) | buffer[9];
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
    payload[i] = masked
      ? buffer[offset + i] ^ maskKey[i % 4]
      : buffer[offset + i];
  }

  const totalBytes = offset + payloadLen;
  return { opcode: opcode, payload: payload.toString('utf-8'), totalBytes: totalBytes };
}

/**
 * Encode a string as a WebSocket frame (server -> client, no mask).
 * @param {string} text - The payload text
 * @param {number} [opcode=0x81] - Frame opcode byte (FIN bit + opcode). Default 0x81 (text).
 */
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
    // 64-bit length, high 4 bytes zero
    header[2] = 0; header[3] = 0; header[4] = 0; header[5] = 0;
    header[6] = (len >> 24) & 0xff;
    header[7] = (len >> 16) & 0xff;
    header[8] = (len >> 8) & 0xff;
    header[9] = len & 0xff;
  }

  return Buffer.concat([header, data]);
}

/**
 * Handle a JSON-RPC 2.0 request message and return the response string.
 */
function _handleJsonRpc(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    return Promise.resolve(
      JSON.stringify({
        jsonrpc: '2.0',
        id: null,
        error: { code: -32700, message: 'Parse error' },
      })
    );
  }

  const id = parsed.id;
  const method = parsed.method;
  const params = parsed.params || {};

  const fn = methods[method];
  if (!fn) {
    return Promise.resolve(
      JSON.stringify({
        jsonrpc: '2.0',
        id: id,
        error: { code: -32601, message: 'Method not found: ' + method },
      })
    );
  }

  return Promise.resolve()
    .then(() => fn(params))
    .then((result) => {
      return JSON.stringify({ jsonrpc: '2.0', id: id, result: result });
    })
    .catch((err) => {
      return JSON.stringify({
        jsonrpc: '2.0',
        id: id,
        error: { code: -32000, message: err.message || String(err) },
      });
    });
}

/**
 * Handle an incoming TCP connection -- either HTTP or WebSocket upgrade.
 */
function _handleConnection(socket) {
  let upgraded = false;
  let buffer = Buffer.alloc(0);

  socket.on('data', (data) => {
    if (upgraded) {
      // WebSocket mode: decode frames
      buffer = Buffer.concat([buffer, Buffer.from(data)]);

      while (buffer.length > 0) {
        const frame = _decodeWsFrame(buffer);
        if (!frame) break;

        // Advance buffer by the exact byte count consumed by the frame
        buffer = buffer.slice(frame.totalBytes);

        if (frame.opcode === 0x08) {
          // Close frame
          const idx = _wsClients.indexOf(socket);
          if (idx !== -1) _wsClients.splice(idx, 1);
          socket.destroy();
          return;
        }

        if (frame.opcode === 0x09) {
          // Ping -> Pong (opcode 0x8A = FIN + pong)
          socket.write(_encodeWsFrame(frame.payload, 0x8a));
          continue;
        }

        if (frame.opcode === 0x01) {
          // Text frame: JSON-RPC request
          _handleJsonRpc(frame.payload).then((response) => {
            try {
              socket.write(_encodeWsFrame(response));
            } catch (e) {
              // Socket may have closed
            }
          });
        }
      }
      return;
    }

    // Initial HTTP request
    const raw = typeof data === 'string' ? data : data.toString('utf-8');
    const req = _parseHttpRequest(raw);

    // WebSocket upgrade?
    if (
      req.headers['upgrade'] &&
      req.headers['upgrade'].toLowerCase() === 'websocket' &&
      req.path === '/ws'
    ) {
      const wsKey = req.headers['sec-websocket-key'];
      if (!wsKey) {
        socket.write(_httpResponse(400, 'Bad Request', {}, 'Missing Sec-WebSocket-Key'));
        socket.destroy();
        return;
      }

      const acceptKey = _computeWsAcceptKey(wsKey);
      const upgradeResp =
        'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        'Sec-WebSocket-Accept: ' + acceptKey + '\r\n' +
        '\r\n';

      socket.write(upgradeResp);
      upgraded = true;
      buffer = Buffer.alloc(0);
      _wsClients.push(socket);
      return;
    }

    // Health check endpoint
    if (req.method === 'GET' && req.path === HEALTH_PATH) {
      const info = {
        framework: FRAMEWORK,
        app_name: _config.appName,
        platform: Platform.OS,
        capabilities: _getCapabilities(),
        sdk_version: SDK_VERSION,
      };
      const body = JSON.stringify(info);
      socket.write(
        _httpResponse(200, 'OK', { 'content-type': 'application/json' }, body)
      );
      socket.destroy();
      return;
    }

    // Unknown path
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

/**
 * Initialize the flutter-skill bridge server inside the React Native app.
 *
 * @param {object} options
 * @param {string} options.appName - Application name reported in health check
 * @param {number} [options.port=18118] - Port to listen on
 */
function initFlutterSkill(options) {
  if (_server) {
    _origLog.call(console, '[flutter-skill] Already initialized');
    return;
  }

  _config = {
    appName: (options && options.appName) || 'ReactNativeApp',
  };

  const port = (options && options.port) || BRIDGE_PORT;

  _installConsoleCapture();

  _server = TcpSocket.createServer((socket) => {
    _handleConnection(socket);
  });

  _server.on('error', (err) => {
    _origLog.call(console, '[flutter-skill] Server error:', err.message);
  });

  _server.listen({ port: port, host: '0.0.0.0' }, () => {
    _origLog.call(
      console,
      '[flutter-skill] Bridge server listening on port ' + port
    );
  });
}

/**
 * Shut down the bridge server (e.g. on app unmount).
 */
function destroyFlutterSkill() {
  if (_server) {
    _wsClients.forEach((s) => {
      try { s.destroy(); } catch (e) { /* ignore */ }
    });
    _wsClients = [];
    _server.close();
    _server = null;
  }
  // Restore original console methods
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
};

export default {
  init: initFlutterSkill,
  destroy: destroyFlutterSkill,
  register: registerComponent,
  unregister: unregisterComponent,
  setNavigationRef: setNavigationRef,
  setRootRef: setRootRef,
};
