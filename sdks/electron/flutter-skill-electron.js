const { WebSocketServer } = require('ws');
const { BrowserWindow } = require('electron');
const http = require('http');

const DEFAULT_PORT = 18118;
const SDK_VERSION = '1.0.0';

class FlutterSkillElectron {
  constructor(options = {}) {
    this.port = options.port || DEFAULT_PORT;
    this.appName = options.appName || 'electron-app';
    this.wss = null;
    this.httpServer = null;
    this.window = options.window || null;
    this.logs = [];
    this.maxLogs = 500;
    this.navigationHistory = ['home'];
  }

  start() {
    // Create HTTP server for health check + WebSocket upgrade
    this.httpServer = http.createServer((req, res) => {
      if (req.url === '/.flutter-skill') {
        res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
        res.end(JSON.stringify({
          framework: 'electron',
          app_name: this.appName,
          platform: 'electron',
          sdk_version: SDK_VERSION,
          capabilities: [
            'initialize', 'inspect', 'inspect_interactive', 'tap', 'enter_text', 'get_text',
            'find_element', 'wait_for_element', 'scroll', 'swipe',
            'screenshot', 'go_back', 'get_logs', 'clear_logs',
          ],
        }));
      } else {
        res.writeHead(404);
        res.end('Not Found');
      }
    });

    this.wss = new WebSocketServer({ server: this.httpServer });
    this.httpServer.listen(this.port, '127.0.0.1');
    console.log(`[flutter-skill-electron] Bridge on port ${this.port}`);

    this.wss.on('connection', (ws) => {
      ws.on('message', async (data) => {
        let req;
        try {
          req = JSON.parse(data);
        } catch {
          ws.send(JSON.stringify({ jsonrpc: '2.0', error: { code: -32700, message: 'Parse error' }, id: null }));
          return;
        }

        try {
          const result = await this._handle(req.method, req.params || {});
          ws.send(JSON.stringify({ jsonrpc: '2.0', result, id: req.id }));
        } catch (err) {
          ws.send(JSON.stringify({
            jsonrpc: '2.0',
            error: { code: -32000, message: err.message || String(err) },
            id: req.id,
          }));
        }
      });
    });
  }

  stop() {
    if (this.wss) this.wss.close();
    if (this.httpServer) this.httpServer.close();
  }

  log(level, message) {
    this.logs.push(`[${level}] ${message}`);
    if (this.logs.length > this.maxLogs) this.logs.shift();
  }

  _getWindow() {
    return this.window || BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0];
  }

  // Resolve a key/selector/text to a CSS selector
  _resolveSelector(params) {
    if (params.selector) return params.selector;
    if (params.key) return `#${params.key}`;
    if (params.element) return params.element;
    return null;
  }

  // Generate JavaScript code to find element by ref ID (semantic fingerprint system)
  _getRefResolutionScript() {
    return `
      function findElementByRef(targetRef) {
        const refCounts = {};
        let foundElement = null;
        
        // Semantic ref generation - generates {role}:{content}[{index}] format
        function generateSemanticRefId(el, elementType) {
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
          
          // Extract content with priority: id > aria-label > text > placeholder > fallback
          let content = el.id ||
                       el.getAttribute('aria-label') ||
                       (el.textContent && el.textContent.trim()) ||
                       el.getAttribute('placeholder') ||
                       el.getAttribute('title') ||
                       null;
          
          if (content) {
            // Clean and format content
            content = content.replace(/\\s+/g, '_')
                            .replace(/[^\\w]/g, '')
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
        
        // Check if this is a legacy ref format (btn_0, tf_1, etc.)
        function isLegacyRef(ref) {
          return /^[a-z]+_\\d+$/.test(ref);
        }
        
        // Handle legacy ref format for backward compatibility
        function findByLegacyRef(refId) {
          const parts = refId.split('_');
          if (parts.length !== 2) return null;
          
          const prefix = parts[0];
          const index = parseInt(parts[1]);
          
          // Map old prefixes to new roles
          const roleMap = {
            btn: 'button',
            tf: 'input',
            sw: 'toggle',
            sl: 'slider',
            dd: 'select',
            lnk: 'link',
            item: 'item'
          };
          
          const role = roleMap[prefix];
          if (!role) return null;
          
          // Find all elements of matching role and get by index
          const matchingElements = [];
          walk(document.body, (el, ref) => {
            if (ref.startsWith(role + ':')) {
              matchingElements.push(el);
            }
          });
          
          return matchingElements[index] || null;
        }
        
        if (isLegacyRef(targetRef)) {
          return findByLegacyRef(targetRef);
        }
        
        function getElementType(el) {
          const tag = el.tagName.toLowerCase();
          if (tag === 'button' || el.matches('[role="button"]') || el.onclick) return 'button';
          if (tag === 'input') {
            const t = el.type.toLowerCase();
            if (t === 'checkbox') return 'checkbox';
            if (t === 'radio') return 'radio';
            if (['text', 'email', 'password', 'search', 'number', 'tel', 'url'].includes(t)) return 'text_field';
            if (t === 'range') return 'slider';
            return 'button';
          }
          if (tag === 'textarea') return 'text_field';
          if (tag === 'select') return 'dropdown';
          if (tag === 'a' && el.href) return 'link';
          if (el.matches('[role="tab"]') || el.closest('[role="tablist"]')) return 'tab';
          if (el.matches('[role="listitem"]') || el.matches('li')) return 'list_item';
          if (el.matches('[role="switch"]')) return 'switch';
          if (el.matches('[role="slider"]')) return 'slider';
          return 'button';
        }
        
        function walk(el, callback) {
          if (!el || el.nodeType !== 1) return;
          const style = window.getComputedStyle(el);
          if (style.display === 'none' || style.visibility === 'hidden') return;

          const isInteractive = el.matches('button, input, select, textarea, a[href], [role="button"], [onclick], [role="tab"], [role="switch"], [role="slider"], li[onclick]') || 
                                el.onclick != null;

          if (isInteractive) {
            const type = getElementType(el);
            const ref = generateSemanticRefId(el, type);
            
            if (callback) {
              callback(el, ref);
            } else if (ref === targetRef) {
              foundElement = el;
              return;
            }
          }

          for (const child of el.children) {
            walk(child, callback);
            if (!callback && foundElement) return;
          }
        }

        walk(document.body);
        return foundElement;
      }
    `;
  }

  async _handle(method, params) {
    const win = this._getWindow();

    switch (method) {
      case 'initialize':
        return {
          success: true,
          framework: 'electron',
          sdk_version: SDK_VERSION,
          platform: 'electron',
        };

      case 'inspect':
        return this._inspect(win);

      case 'inspect_interactive':
        return this._inspectInteractive(win);

      case 'tap':
        return this._tap(win, params);

      case 'enter_text':
        return this._enterText(win, params);

      case 'get_text':
        return this._getText(win, params);

      case 'find_element':
        return this._findElement(win, params);

      case 'wait_for_element':
        return this._waitForElement(win, params);

      case 'scroll':
        return this._scroll(win, params);

      case 'swipe':
        return this._swipe(win, params);

      case 'screenshot':
        return this._screenshot(win);

      case 'go_back':
        return this._goBack(win);

      case 'get_logs':
        return { logs: [...this.logs] };

      case 'clear_logs':
        this.logs = [];
        return { success: true };

      default:
        throw new Error(`Unknown method: ${method}`);
    }
  }

  async _inspect(win) {
    if (!win) return { elements: [] };
    const elements = await win.webContents.executeJavaScript(`
      (function() {
        const results = [];
        function walk(el) {
          if (!el || el.nodeType !== 1) return;
          const style = window.getComputedStyle(el);
          if (style.display === 'none' || style.visibility === 'hidden') return;

          const tag = el.tagName.toLowerCase();
          const isInteractive = el.matches('button, input, select, textarea, a, [role="button"], [onclick], label');
          const hasId = !!el.id;
          const hasText = !el.children.length && (el.textContent || '').trim().length > 0;

          if (isInteractive || hasId || hasText) {
            const rect = el.getBoundingClientRect();
            results.push({
              type: _mapType(el),
              key: el.id || null,
              tag: tag,
              text: (el.value || el.textContent || '').trim().slice(0, 200) || null,
              bounds: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
              visible: rect.width > 0 && rect.height > 0,
              enabled: !el.disabled,
              clickable: el.matches('button, a, [role="button"], [onclick]') || el.onclick != null,
            });
          }

          for (const child of el.children) walk(child);
        }

        function _mapType(el) {
          const tag = el.tagName.toLowerCase();
          if (tag === 'button' || el.matches('[role="button"]')) return 'button';
          if (tag === 'input') {
            const t = el.type;
            if (t === 'checkbox') return 'checkbox';
            if (t === 'radio') return 'radio';
            if (t === 'text' || t === 'email' || t === 'password' || t === 'search' || t === 'number') return 'text_field';
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

        walk(document.body);
        return results;
      })();
    `);
    return { elements };
  }

  async _inspectInteractive(win) {
    if (!win) return { elements: [], summary: 'No window available' };
    
    const result = await win.webContents.executeJavaScript(`
      (function() {
        const elements = [];
        const refCounts = {};
        
        // Semantic ref generation - generates {role}:{content}[{index}] format
        function generateSemanticRefId(el, elementType) {
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
          
          // Extract content with priority: id > aria-label > text > placeholder > fallback
          let content = el.id ||
                       el.getAttribute('aria-label') ||
                       (el.textContent && el.textContent.trim()) ||
                       el.getAttribute('placeholder') ||
                       el.getAttribute('title') ||
                       null;
          
          if (content) {
            // Clean and format content
            content = content.replace(/\\s+/g, '_')
                            .replace(/[^\\w]/g, '')
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
        
        function getElementType(el) {
          const tag = el.tagName.toLowerCase();
          if (tag === 'button' || el.matches('[role="button"]') || el.onclick) return 'button';
          if (tag === 'input') {
            const t = el.type.toLowerCase();
            if (t === 'checkbox') return 'checkbox';
            if (t === 'radio') return 'radio';
            if (['text', 'email', 'password', 'search', 'number', 'tel', 'url'].includes(t)) return 'text_field';
            if (t === 'range') return 'slider';
            return 'button'; // For other input types like submit, button
          }
          if (tag === 'textarea') return 'text_field';
          if (tag === 'select') return 'dropdown';
          if (tag === 'a' && el.href) return 'link';
          if (el.matches('[role="tab"]') || el.closest('[role="tablist"]')) return 'tab';
          if (el.matches('[role="listitem"]') || el.matches('li')) return 'list_item';
          if (el.matches('[role="switch"]')) return 'switch';
          if (el.matches('[role="slider"]')) return 'slider';
          return 'button'; // Fallback for clickable elements
        }
        
        function getActions(el, type) {
          const actions = [];
          if (type === 'text_field') {
            actions.push('tap', 'enter_text');
          } else if (type === 'slider') {
            actions.push('tap', 'swipe');
          } else {
            actions.push('tap');
            if (el.matches('button, [role="button"], a') || el.onclick) {
              actions.push('long_press');
            }
          }
          return actions;
        }
        
        function getValue(el, type) {
          if (type === 'text_field') {
            return el.value || '';
          } else if (type === 'checkbox' || type === 'switch') {
            return el.checked || false;
          } else if (type === 'dropdown') {
            return el.value || el.selectedOptions[0]?.text || '';
          } else if (type === 'slider') {
            return parseFloat(el.value) || 0;
          }
          return undefined;
        }
        
        function walk(el) {
          if (!el || el.nodeType !== 1) return;
          const style = window.getComputedStyle(el);
          if (style.display === 'none' || style.visibility === 'hidden') return;

          const tag = el.tagName.toLowerCase();
          const isInteractive = el.matches('button, input, select, textarea, a[href], [role="button"], [onclick], [role="tab"], [role="switch"], [role="slider"], li[onclick]') || 
                                el.onclick != null;

          if (isInteractive) {
            const type = getElementType(el);
            const rect = el.getBoundingClientRect();
            const text = (el.textContent || el.value || el.alt || el.title || '').trim();
            const label = el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || '';
            
            // Generate ref ID
            const ref = generateSemanticRefId(el, type);
            
            const element = {
              ref: ref,
              type: el.tagName + (el.type ? '[' + el.type + ']' : ''),
              text: text.slice(0, 100) || null,
              actions: getActions(el, type),
              enabled: !el.disabled && !el.readOnly,
              bounds: {
                x: Math.round(rect.x),
                y: Math.round(rect.y),
                w: Math.round(rect.width),
                h: Math.round(rect.height)
              }
            };

            // Add optional fields
            if (label) element.label = label;
            const value = getValue(el, type);
            if (value !== undefined) element.value = value;

            elements.push(element);
          }

          // Recursively walk children
          for (const child of el.children) {
            walk(child);
          }
        }

        walk(document.body);
        
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

        return { elements, summary };
      })();
    `);
    
    return result;
  }

  async _tap(win, params) {
    if (!win) return { success: false, message: 'No window' };
    const sel = this._resolveSelector(params);
    const textMatch = params.text;
    const refId = params.ref;

    const result = await win.webContents.executeJavaScript(`
      (function() {
        let el = null;
        
        // Try ref ID first if provided
        if (${JSON.stringify(refId)}) {
          // Get ref to element mapping from inspect_interactive
          ${this._getRefResolutionScript()}
          el = findElementByRef(${JSON.stringify(refId)});
        }
        
        // Fallback to selector
        if (!el && ${JSON.stringify(sel)}) {
          el = document.querySelector(${JSON.stringify(sel || '')});
        }
        
        // Fallback to text search
        if (!el && ${JSON.stringify(textMatch)}) {
          const tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (tw.nextNode()) {
            if (tw.currentNode.textContent.includes(${JSON.stringify(textMatch || '')})) {
              el = tw.currentNode.parentElement;
              break;
            }
          }
        }
        
        if (!el) return { success: false, message: 'Element not found' };
        el.click();
        return { success: true, method: ${JSON.stringify(refId ? 'ref' : sel ? 'selector' : 'text')} };
      })();
    `);
    return result;
  }

  async _enterText(win, params) {
    if (!win) return { success: false, message: 'No window' };
    const sel = this._resolveSelector(params);
    const text = params.text || '';
    const refId = params.ref;
    
    if (!sel && !refId) return { success: false, message: 'Missing key/selector/ref' };

    const result = await win.webContents.executeJavaScript(`
      (function() {
        let el = null;
        
        // Try ref ID first if provided
        if (${JSON.stringify(refId)}) {
          ${this._getRefResolutionScript()}
          el = findElementByRef(${JSON.stringify(refId)});
        }
        
        // Fallback to selector
        if (!el && ${JSON.stringify(sel)}) {
          el = document.querySelector(${JSON.stringify(sel)});
        }
        
        if (!el) return { success: false, message: 'Element not found' };
        
        // Check if element can accept text input
        if (!el.matches('input, textarea, select') && !el.isContentEditable) {
          return { success: false, message: 'Element is not a text input field' };
        }
        
        el.focus();
        if (el.matches('input, textarea')) {
          el.value = ${JSON.stringify(text)};
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (el.isContentEditable) {
          el.textContent = ${JSON.stringify(text)};
          el.dispatchEvent(new Event('input', { bubbles: true }));
        }
        
        return { success: true, method: ${JSON.stringify(refId ? 'ref' : 'selector')} };
      })();
    `);
    return result;
  }

  async _getText(win, params) {
    if (!win) return { text: null };
    const sel = this._resolveSelector(params);
    if (!sel) return { text: null };

    const result = await win.webContents.executeJavaScript(`
      (function() {
        const el = document.querySelector(${JSON.stringify(sel)});
        if (!el) return { text: null };
        return { text: (el.value || el.textContent || '').trim() };
      })();
    `);
    return result;
  }

  async _findElement(win, params) {
    if (!win) return { found: false };
    const sel = this._resolveSelector(params);
    const textMatch = params.text;

    const result = await win.webContents.executeJavaScript(`
      (function() {
        if (${JSON.stringify(sel)}) {
          const el = document.querySelector(${JSON.stringify(sel || '')});
          if (el) {
            const rect = el.getBoundingClientRect();
            return { found: true, element: {
              tag: el.tagName.toLowerCase(),
              key: el.id || null,
              text: (el.value || el.textContent || '').trim().slice(0, 200),
              bounds: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
            }};
          }
        }
        if (${JSON.stringify(textMatch)}) {
          const tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (tw.nextNode()) {
            if (tw.currentNode.textContent.includes(${JSON.stringify(textMatch || '')})) {
              const p = tw.currentNode.parentElement;
              return { found: true, element: { tag: p.tagName.toLowerCase(), key: p.id || null, text: tw.currentNode.textContent.trim().slice(0, 200) }};
            }
          }
        }
        return { found: false };
      })();
    `);
    return result;
  }

  async _waitForElement(win, params) {
    if (!win) return { found: false };
    const sel = this._resolveSelector(params);
    const textMatch = params.text;
    const timeout = params.timeout || 5000;

    const result = await win.webContents.executeJavaScript(`
      new Promise((resolve) => {
        const start = Date.now();
        const check = () => {
          let found = false;
          if (${JSON.stringify(sel)}) {
            found = !!document.querySelector(${JSON.stringify(sel || '')});
          } else if (${JSON.stringify(textMatch)}) {
            const tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            while (tw.nextNode()) {
              if (tw.currentNode.textContent.includes(${JSON.stringify(textMatch || '')})) { found = true; break; }
            }
          }
          if (found) return resolve({ found: true });
          if (Date.now() - start > ${timeout}) return resolve({ found: false });
          requestAnimationFrame(check);
        };
        check();
      });
    `);
    return result;
  }

  async _scroll(win, params) {
    if (!win) return { success: false };
    const direction = params.direction || 'down';
    const distance = params.distance || 300;
    const sel = this._resolveSelector(params);

    let dx = 0, dy = 0;
    switch (direction) {
      case 'up': dy = -distance; break;
      case 'down': dy = distance; break;
      case 'left': dx = -distance; break;
      case 'right': dx = distance; break;
    }

    await win.webContents.executeJavaScript(`
      (function() {
        const target = ${sel ? `document.querySelector(${JSON.stringify(sel)})` : 'null'} || document.scrollingElement || document.body;
        target.scrollBy(${dx}, ${dy});
      })();
    `);
    return { success: true };
  }

  async _swipe(win, params) {
    // Swipe = scroll for web contexts
    return this._scroll(win, params);
  }

  async _screenshot(win) {
    if (!win) return { success: false, message: 'No window' };
    const image = await win.webContents.capturePage();
    const base64 = image.toPNG().toString('base64');
    return { success: true, image: base64, format: 'png', encoding: 'base64' };
  }

  async _goBack(win) {
    if (!win) return { success: false, message: 'No window' };

    // Try app-level back handler first (SPA navigation)
    const handled = await win.webContents.executeJavaScript(`
      (function() {
        // Check for custom back handler
        if (typeof window.__flutterSkillGoBack === 'function') {
          window.__flutterSkillGoBack();
          return true;
        }
        // Try clicking a visible back button
        const backBtns = document.querySelectorAll('[id*="back"], [class*="back"], [aria-label*="back"], [aria-label*="Back"]');
        for (const btn of backBtns) {
          if (btn.offsetParent !== null) { btn.click(); return true; }
        }
        return false;
      })();
    `);

    if (handled) return { success: true };

    // Fall back to browser navigation
    const canGoBack = win.webContents.canGoBack();
    if (canGoBack) {
      win.webContents.goBack();
      return { success: true };
    }

    await win.webContents.executeJavaScript('window.history.back()');
    return { success: true };
  }
}

module.exports = { FlutterSkillElectron };
