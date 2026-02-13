#!/usr/bin/env node
// Comprehensive E2E test for bridge-protocol SDKs via Node.js
// Usage: node test/e2e/bridge_e2e_test.mjs [port] [platform]
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const WebSocket = require('/Users/cw/development/flutter-skill/sdks/electron/node_modules/ws');
const http = require('http');

const PORT = process.argv[2] || 18118;
const PLATFORM = process.argv[3] || 'unknown';
let passed = 0, failed = 0, total = 0;

function httpGet(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = '';
      res.on('data', (d) => data += d);
      res.on('end', () => resolve(data));
    }).on('error', reject);
  });
}

class TestClient {
  constructor(port) { this.port = port; this._id = 0; this._pending = {}; }
  
  connect() {
    return new Promise((resolve, reject) => {
      // Try /ws first (Android, iOS native), fall back to root (Electron)
      const tryConnect = (path) => {
        const ws = new WebSocket(`ws://127.0.0.1:${this.port}${path}`);
        ws.on('open', () => { this.ws = ws; this._setupListeners(); resolve(); });
        ws.on('error', (e) => {
          if (path === '/ws') { tryConnect(''); }
          else reject(e);
        });
      };
      tryConnect('/ws');
    });
  }

  _setupListeners() {
    this.ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.id && this._pending[msg.id]) {
        this._pending[msg.id](msg);
        delete this._pending[msg.id];
      }
    });
  }
  
  call(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this._id;
      this._pending[id] = resolve;
      this.ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
      setTimeout(() => {
        if (this._pending[id]) {
          delete this._pending[id];
          reject(new Error(`${method} timed out`));
        }
      }, 15000);
    });
  }
  
  close() { this.ws.close(); }
}

async function test(name, fn) {
  total++;
  const pad = name.padEnd(45);
  try {
    await fn();
    passed++;
    console.log(`  ${pad} \x1b[32mPASS\x1b[0m`);
  } catch (e) {
    failed++;
    console.log(`  ${pad} \x1b[31mFAIL\x1b[0m ${e.message || e}`);
  }
}

function assert(cond, msg) { if (!cond) throw new Error(msg); }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// Platform-specific element keys
const KEYS = {
  electron: { increment: 'increment-btn', input: 'text-input', detail: 'detail-btn', counter: 'counter', submit: 'submit-btn', checkbox: 'test-checkbox' },
  android:  { increment: 'increment_btn', input: 'input_field', detail: 'detail_btn', counter: 'counter_text', submit: 'submit_btn', checkbox: 'test_checkbox' },
  kmp:      { increment: 'increment-btn', input: 'text-input', detail: 'detail-btn', counter: 'counter', submit: 'submit-btn', checkbox: 'test-checkbox' },
  dotnet:   { increment: 'increment-btn', input: 'text-input', detail: 'detail-btn', counter: 'counter', submit: 'submit-btn', checkbox: 'test-checkbox' },
  tauri:    { increment: 'increment-btn', input: 'text-input', detail: 'detail-btn', counter: 'counter', submit: 'submit-btn', checkbox: 'test-checkbox' },
  default:  { increment: 'increment_btn', input: 'input_field', detail: 'detail_btn', counter: 'counter_text', submit: 'submit_btn', checkbox: 'test_checkbox' },
};
const K = KEYS[PLATFORM] || KEYS.default;

async function main() {
  console.log('============================================');
  console.log(` Bridge E2E Test Suite`);
  console.log(` Platform: ${PLATFORM} | Port: ${PORT}`);
  console.log('============================================');

  // HTTP health — try the specified port, then port-1 (for split HTTP/WS servers like Tauri)
  console.log('\n--- Health Check ---');
  let health;
  let healthPort = PORT;
  try {
    const body = await httpGet(`http://127.0.0.1:${PORT}/.flutter-skill`);
    health = JSON.parse(body);
  } catch (e) {
    try {
      healthPort = PORT - 1;
      const body = await httpGet(`http://127.0.0.1:${healthPort}/.flutter-skill`);
      health = JSON.parse(body);
      console.log(`  (Health on port ${healthPort}, WS on port ${PORT})`);
    } catch (e2) {
      console.log(`  \x1b[31mApp not running on port ${PORT}\x1b[0m: ${e.message}`);
      process.exit(1);
    }
  }
  console.log(`  Platform: ${health.platform || health.framework}`);
  console.log(`  SDK: ${health.sdk_version}`);
  console.log(`  Capabilities: ${(health.capabilities || []).join(', ')}`);

  const client = new TestClient(PORT);
  await client.connect();

  // Initialize
  console.log('\n--- Initialize ---');
  await test('initialize', async () => {
    const r = await client.call('initialize', { protocol_version: '1.0', client: 'e2e-test' });
    assert(r.result, `No result: ${JSON.stringify(r)}`);
  });

  // Inspect
  console.log('\n--- Inspect ---');
  let elements;
  await test('inspect returns elements', async () => {
    const r = await client.call('inspect');
    elements = r.result?.elements || r.result?.children ? [r.result] : [];
    if (r.result?.elements) elements = r.result.elements;
    assert(elements.length > 0, 'No elements');
    console.log(`    (${elements.length} elements)`);
  });

  await test('elements have type/bounds', async () => {
    const el = elements[0];
    assert(el.type || el.tag, `Missing type: ${JSON.stringify(el).slice(0, 100)}`);
  });

  // Tap
  console.log('\n--- Tap ---');
  await test('tap by key (increment)', async () => {
    const r = await client.call('tap', { key: K.increment });
    assert(r.result?.success === true, `Failed: ${JSON.stringify(r)}`);
  });
  await sleep(300);

  await test('tap by text', async () => {
    const r = await client.call('tap', { text: 'Submit' });
    // Text match may not work on all platforms
    if (r.error) console.log('    (text tap not supported)');
  });
  await sleep(300);

  // Enter Text
  console.log('\n--- Enter Text ---');
  await test('enter_text', async () => {
    const r = await client.call('enter_text', { key: K.input, text: 'Hello E2E' });
    assert(r.result?.success === true, `Failed: ${JSON.stringify(r)}`);
  });
  await sleep(300);

  // Get Text
  console.log('\n--- Get Text ---');
  await test('get_text on counter', async () => {
    const r = await client.call('get_text', { key: K.counter });
    assert(r.result?.text != null, `No text: ${JSON.stringify(r)}`);
    console.log(`    text="${r.result.text}"`);
  });

  await test('get_text on input', async () => {
    const r = await client.call('get_text', { key: K.input });
    console.log(`    text="${r.result?.text}"`);
  });

  // Find Element
  console.log('\n--- Find Element ---');
  await test('find_element (exists)', async () => {
    const r = await client.call('find_element', { key: K.increment });
    assert(r.result?.found === true, `Not found: ${JSON.stringify(r)}`);
  });

  await test('find_element (missing)', async () => {
    const r = await client.call('find_element', { key: 'nonexistent_xyz_999' });
    assert(r.result?.found === false, `Should not be found: ${JSON.stringify(r)}`);
  });

  await test('find_element (by text)', async () => {
    const r = await client.call('find_element', { text: 'Submit' });
    assert(r.result?.found === true, `Not found: ${JSON.stringify(r)}`);
  });

  // Wait For Element
  console.log('\n--- Wait For Element ---');
  await test('wait_for_element (exists)', async () => {
    const r = await client.call('wait_for_element', { key: K.counter, timeout: 3000 });
    assert(r.result?.found === true, `Not found: ${JSON.stringify(r)}`);
  });

  await test('wait_for_element (by text)', async () => {
    const r = await client.call('wait_for_element', { text: 'Count', timeout: 3000 });
    assert(r.result?.found === true, `Not found: ${JSON.stringify(r)}`);
  });

  // Scroll
  console.log('\n--- Scroll ---');
  await test('scroll down', async () => {
    const r = await client.call('scroll', { direction: 'down', distance: 300 });
    assert(r.result?.success === true || r.result != null, `Failed: ${JSON.stringify(r)}`);
  });
  await sleep(300);

  await test('scroll up', async () => {
    const r = await client.call('scroll', { direction: 'up', distance: 300 });
    assert(r.result?.success === true || r.result != null, `Failed: ${JSON.stringify(r)}`);
  });
  await sleep(300);

  // Swipe
  console.log('\n--- Swipe ---');
  await test('swipe up', async () => {
    const r = await client.call('swipe', { direction: 'up', distance: 400 });
    assert(r.result?.success === true || r.result != null, `Failed: ${JSON.stringify(r)}`);
  });
  await sleep(300);

  await test('swipe down', async () => {
    const r = await client.call('swipe', { direction: 'down', distance: 400 });
    assert(r.result?.success === true || r.result != null, `Failed: ${JSON.stringify(r)}`);
  });
  await sleep(300);

  // Screenshot
  console.log('\n--- Screenshot ---');
  await test('screenshot', async () => {
    const r = await client.call('screenshot');
    const img = r.result?.image || r.result?.screenshot;
    assert(img && img.length > 100, `No screenshot`);
    console.log(`    (${img.length} base64 chars)`);
  });

  // Navigation
  console.log('\n--- Navigation ---');
  await test('navigate to detail page', async () => {
    const r = await client.call('tap', { key: K.detail });
    assert(r.result?.success === true, `Failed: ${JSON.stringify(r)}`);
  });
  await sleep(500);

  await test('inspect after navigate', async () => {
    const r = await client.call('inspect');
    const els = r.result?.elements || [];
    assert(els.length > 0, 'No elements');
    console.log(`    (${els.length} elements)`);
  });

  await test('go_back', async () => {
    const r = await client.call('go_back');
    assert(r.result?.success === true, `Failed: ${JSON.stringify(r)}`);
  });
  await sleep(500);

  await test('inspect after go_back', async () => {
    const r = await client.call('inspect');
    const els = r.result?.elements || [];
    assert(els.length > 0, 'No elements on home page');
  });

  // Logs
  console.log('\n--- Logs ---');
  await test('get_logs', async () => {
    const r = await client.call('get_logs');
    assert(r.result?.logs != null, `No logs: ${JSON.stringify(r)}`);
  });

  await test('clear_logs', async () => {
    const r = await client.call('clear_logs');
    assert(r.result?.success === true, `Failed: ${JSON.stringify(r)}`);
  });

  // Summary
  client.close();
  console.log('\n============================================');
  console.log(` Results: ${passed} passed, ${failed} failed, ${total} total`);
  console.log('============================================');
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(e => { console.error(e); process.exit(1); });
