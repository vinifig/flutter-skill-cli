const { WebSocketServer } = require('ws');
const { BrowserWindow } = require('electron');

const DEFAULT_PORT = 18118;

class FlutterSkillElectron {
  constructor(options = {}) {
    this.port = options.port || DEFAULT_PORT;
    this.wss = null;
    this.window = options.window || null;
  }

  start() {
    this.wss = new WebSocketServer({ port: this.port });
    console.log(`[flutter-skill-electron] WebSocket server on port ${this.port}`);

    this.wss.on('connection', (ws) => {
      ws.on('message', async (data) => {
        let req;
        try {
          req = JSON.parse(data);
        } catch {
          ws.send(JSON.stringify({ jsonrpc: '2.0', error: { code: -32700, message: 'Parse error' }, id: null }));
          return;
        }

        const result = await this._handle(req.method, req.params || {});
        if (result.error) {
          ws.send(JSON.stringify({ jsonrpc: '2.0', error: { code: -32000, message: result.error }, id: req.id }));
        } else {
          ws.send(JSON.stringify({ jsonrpc: '2.0', result: result, id: req.id }));
        }
      });
    });
  }

  stop() {
    if (this.wss) this.wss.close();
  }

  _getWindow() {
    return this.window || BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0];
  }

  async _handle(method, params) {
    const win = this._getWindow();
    if (!win && method !== 'health') return { error: 'No BrowserWindow available' };

    switch (method) {
      case 'health':
        return { status: 'ok', platform: 'electron', pid: process.pid };

      case 'inspect':
        return await win.webContents.executeJavaScript(`
          (function walk(el, depth) {
            if (!el) return null;
            const tag = el.tagName ? el.tagName.toLowerCase() : '#text';
            const attrs = {};
            if (el.id) attrs.id = el.id;
            if (el.className) attrs.class = String(el.className);
            const text = el.childNodes.length === 0 ? (el.textContent || '').trim().slice(0, 200) : undefined;
            const children = [];
            for (const c of (el.children || [])) { if (depth < 15) children.push(walk(c, depth + 1)); }
            return { tag, attrs, text, children };
          })(document.body, 0);
        `);

      case 'tap': {
        const sel = params.selector || params.element;
        if (!sel) return { error: 'selector required' };
        return await win.webContents.executeJavaScript(`
          (function() {
            const el = document.querySelector(${JSON.stringify(sel)});
            if (!el) return { error: 'Element not found' };
            el.click();
            return { tapped: true };
          })();
        `);
      }

      case 'enter_text': {
        const sel = params.selector || params.element;
        const text = params.text || '';
        if (!sel) return { error: 'selector required' };
        return await win.webContents.executeJavaScript(`
          (function() {
            const el = document.querySelector(${JSON.stringify(sel)});
            if (!el) return { error: 'Element not found' };
            el.focus();
            el.value = ${JSON.stringify(text)};
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return { entered: true };
          })();
        `);
      }

      case 'screenshot': {
        const image = await win.webContents.capturePage();
        return { screenshot: image.toPNG().toString('base64'), format: 'png' };
      }

      case 'scroll': {
        const dx = params.dx || 0;
        const dy = params.dy || 0;
        await win.webContents.executeJavaScript(`window.scrollBy(${dx}, ${dy})`);
        return { scrolled: true };
      }

      case 'get_text': {
        const sel = params.selector || params.element;
        if (!sel) return { error: 'selector required' };
        return await win.webContents.executeJavaScript(`
          (function() {
            const el = document.querySelector(${JSON.stringify(sel)});
            return el ? { text: el.textContent.trim() } : { error: 'Element not found' };
          })();
        `);
      }

      case 'find_element': {
        const sel = params.selector;
        const textMatch = params.text;
        return await win.webContents.executeJavaScript(`
          (function() {
            if (${JSON.stringify(sel)}) {
              const el = document.querySelector(${JSON.stringify(sel || '')});
              return el ? { found: true, tag: el.tagName.toLowerCase(), text: el.textContent.trim().slice(0, 200) } : { found: false };
            }
            if (${JSON.stringify(textMatch)}) {
              const tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
              while (tw.nextNode()) {
                if (tw.currentNode.textContent.includes(${JSON.stringify(textMatch || '')})) {
                  const p = tw.currentNode.parentElement;
                  return { found: true, tag: p.tagName.toLowerCase(), selector: p.id ? '#'+p.id : p.tagName.toLowerCase() };
                }
              }
              return { found: false };
            }
            return { error: 'selector or text required' };
          })();
        `);
      }

      case 'wait_for_element': {
        const sel = params.selector;
        const timeout = params.timeout || 5000;
        return await win.webContents.executeJavaScript(`
          new Promise((resolve) => {
            const start = Date.now();
            const check = () => {
              const el = document.querySelector(${JSON.stringify(sel || '')});
              if (el) return resolve({ found: true });
              if (Date.now() - start > ${timeout}) return resolve({ found: false, error: 'timeout' });
              requestAnimationFrame(check);
            };
            check();
          });
        `);
      }

      default:
        return { error: `Unknown method: ${method}` };
    }
  }
}

module.exports = { FlutterSkillElectron };
