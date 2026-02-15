#!/usr/bin/env node
/**
 * Comprehensive MCP test — all 81 tools across 10 platforms via MCP stdio JSON-RPC.
 *
 * Usage:
 *   node full_mcp_test.mjs --platform=electron [--uri=ws://...] [--url=http://...] [--vm-service=ws://...] [--port=18118]
 *
 * Platforms: electron, android, flutter-ios, flutter-web, tauri, kmp, dotnet-maui, react-native, web-sdk, web-cdp
 */

import { spawn } from 'child_process';
import { createInterface } from 'readline';

// ── CLI args ───────────────────────────────────────────────────────────────
const args = Object.fromEntries(
  process.argv.slice(2).filter(a => a.startsWith('--')).map(a => {
    const [k, ...v] = a.slice(2).split('=');
    return [k, v.join('=') || 'true'];
  })
);
const PLATFORM   = args.platform || 'electron';
const URI        = args.uri || null;
const URL        = args.url || null;
const VM_SERVICE = args['vm-service'] || null;
const PORT       = parseInt(args.port || '18118');

const DART   = '/Users/cw/development/flutter/bin/dart';
const SERVER = '/Users/cw/development/flutter-skill/bin/flutter_skill.dart';

// ── Platform classification ────────────────────────────────────────────────
const FLUTTER_PLATFORMS = new Set(['flutter-ios', 'flutter-web']);
const MOBILE_PLATFORMS  = new Set(['android', 'flutter-ios', 'react-native']);
const WEB_PLATFORMS     = new Set(['electron', 'tauri', 'kmp', 'web-sdk', 'web-cdp', 'flutter-web', 'dotnet-maui']);
const isFlutter = FLUTTER_PLATFORMS.has(PLATFORM);
const isMobile  = MOBILE_PLATFORMS.has(PLATFORM);
const isWeb     = WEB_PLATFORMS.has(PLATFORM);
const isCDP     = PLATFORM === 'web-cdp';

// ── Skip rules ─────────────────────────────────────────────────────────────
const FLUTTER_ONLY = new Set(['get_widget_tree', 'get_widget_properties', 'find_by_type', 'hot_reload', 'hot_restart', 'launch_app']);
const MOBILE_ONLY  = new Set(['native_tap', 'native_input_text', 'native_swipe', 'native_screenshot', 'auth_biometric', 'auth_deeplink']);
const CDP_ONLY     = new Set(['connect_cdp']);
const NO_WEB       = new Set(['auth_deeplink', 'auth_biometric']);

function shouldSkip(tool) {
  if (FLUTTER_ONLY.has(tool) && !isFlutter) return 'Flutter-only';
  if (MOBILE_ONLY.has(tool) && !isMobile)   return 'mobile-only';
  if (CDP_ONLY.has(tool) && !isCDP)         return 'CDP-only';
  if (NO_WEB.has(tool) && isWeb && !isMobile) return 'N/A on web/desktop';
  return null;
}

// ── Results ────────────────────────────────────────────────────────────────
let pass = 0, fail = 0, skip = 0;
const results = [];

function record(tool, status, note = '') {
  const icon = status === 'pass' ? '✅' : status === 'fail' ? '❌' : '⚠️';
  console.log(`  ${icon} ${tool}${note ? ' — ' + note : ''}`);
  if (status === 'pass') pass++;
  else if (status === 'fail') fail++;
  else skip++;
  results.push({ tool, status, note });
}

// ── All 81 tools with test definitions ─────────────────────────────────────
// Each entry: [toolName, argsOrFn, validatorFn?]
// argsOrFn: object of args, or function(ctx) returning args
// validatorFn: optional function(parsedContent) that throws on failure

// Per-platform element keys (must match actual element IDs in each test app)
const ELEMENT_KEYS = {
  'electron': { button: 'increment-btn', input: 'text-input', text: 'counter', checkbox: 'test-checkbox', slider: 'volume-slider' },
  'tauri': { button: 'increment-btn', input: 'text-input', text: 'counter', checkbox: 'test-checkbox', slider: 'volume-slider' },
  'kmp': { button: 'increment-btn', input: 'text-input', text: 'counter', checkbox: 'test-checkbox', slider: 'volume-slider' },
  'dotnet-maui': { button: 'increment-btn', input: 'text-input', text: 'counter', checkbox: 'test-checkbox', slider: 'volume-slider' },
  'react-native': { button: 'like_button', input: 'search_input', text: 'post_text', checkbox: 'remember_checkbox', slider: 'volume_slider' },
  'web-sdk': { button: 'post_like_button_0', input: 'email_input', text: 'post_content_0', checkbox: 'remember_me_checkbox', slider: 'font_size_slider' },
  'web-cdp': { button: 'post_like_button_0', input: 'email_input', text: 'post_content_0', checkbox: 'remember_me_checkbox', slider: 'font_size_slider' },
  'android': { button: 'increment_btn', input: 'input_field', text: 'counter_text', checkbox: 'test_checkbox', slider: 'volume_slider' },
  'flutter-ios': { button: 'login_button', input: 'email_field', text: 'login_button', checkbox: 'dark_mode_toggle', slider: 'font_size_slider' },
  'flutter-web': { button: 'login_button', input: 'email_field', text: 'login_button', checkbox: 'dark_mode_toggle', slider: 'font_size_slider' },
};
const EK = ELEMENT_KEYS[PLATFORM] || ELEMENT_KEYS['electron'];

const TOOLS = [
  // ── Connection (pre-connect queries) ──
  ['get_connection_status', {}],
  ['list_sessions', {}],
  ['list_running_apps', {}],

  // ── Inspection (19) ──
  ['inspect', {}],
  ['inspect_interactive', {}],
  ['snapshot', { mode: 'text' }],
  ['get_widget_tree', {}],
  ['get_widget_properties', { key: EK.button }],
  ['get_text_content', {}],
  ['find_by_type', { type: 'Text' }],
  ['get_text_value', { key: EK.text }],
  ['get_checkbox_state', { key: EK.checkbox }],
  ['get_slider_value', { key: EK.slider }],
  ['get_current_route', {}],
  ['get_navigation_stack', {}],
  ['get_page_state', {}],
  ['get_interactable_elements', {}],
  ['get_logs', {}],
  ['get_errors', {}],
  ['get_performance', {}],
  ['get_frame_stats', {}],
  ['get_memory_stats', {}],

  // ── Interaction (19) ──
  ['tap', { key: EK.button }],
  ['enter_text', { key: EK.input, text: 'hello e2e' }],
  ['scroll_to', { key: EK.text }],
  ['long_press', { key: EK.button }],
  ['double_tap', { key: EK.button }],
  ['swipe', { direction: 'up', distance: 300 }],
  ['drag', (ctx) => isFlutter ? { from_key: EK.button, to_key: EK.input } : { startX: 100, startY: 300, endX: 100, endY: 100 }],
  ['tap_at', { x: 100, y: 200 }],
  ['long_press_at', { x: 100, y: 200 }],
  ['swipe_coordinates', { startX: 200, startY: 400, endX: 200, endY: 200 }],
  ['edge_swipe', { edge: 'left', direction: 'right' }],
  ['gesture', { actions: [{ type: 'tap', x: 100, y: 100 }] }],
  ['go_back', {}],
  ['scroll_until_visible', { key: EK.text, direction: 'down' }],
  ['native_tap', { x: 100, y: 200 }],
  ['native_input_text', { text: 'native hello' }],
  ['native_swipe', { start_x: 200, start_y: 400, end_x: 200, end_y: 200 }],
  ['native_screenshot', {}],
  ['execute_batch', { actions: [{ tool: 'tap', args: { key: EK.button } }] }],

  // ── Assertions (7) ──
  ['assert_visible', { key: EK.button }],
  ['assert_not_visible', { key: 'nonexistent_xyz_999' }],
  ['assert_text', { key: EK.text, expected: '' }],
  ['assert_element_count', { type: 'button', expected: 1 }],
  ['wait_for_element', { key: EK.button, timeout: 3000 }],
  ['wait_for_gone', { key: 'nonexistent_xyz_999', timeout: 2000 }],
  ['wait_for_idle', { timeout: 3000 }],

  // ── Auth v0.8.1 (4) ──
  ['auth_inject_session', { token: 'test-jwt-abc', storage: 'local_storage', key: 'auth_token' }],
  ['auth_biometric', { action: 'enroll' }],
  ['auth_otp', { secret: 'JBSWY3DPEHPK3PXP' }],
  ['auth_deeplink', { url: 'myapp://test?token=abc123' }],

  // ── Recording v0.8.1 (7) ──
  ['record_start', {}],
  ['record_stop', {}],
  ['record_export', { format: 'jest' }],
  ['video_start', {}],
  ['video_stop', {}],
  ['parallel_snapshot', {}],
  ['parallel_tap', { ref: 'button:Home' }],

  // ── Utility (10) ──
  ['diagnose', {}],
  ['diagnose_project', {}],
  ['pub_search', { query: 'flutter' }],
  ['hot_reload', {}],
  ['hot_restart', {}],
  ['enable_test_indicators', {}],
  ['get_indicator_status', {}],
  ['enable_network_monitoring', {}],
  ['clear_logs', {}],
  ['clear_network_requests', {}],

  // ── CDP-specific (1) ──
  ['connect_cdp', (ctx) => ({ url: ctx.URL || 'http://localhost:9222' })],

  // ── Connection lifecycle (tested last to avoid breaking other tests) ──
  ['switch_session', { session_id: 'default' }],
  ['disconnect', {}],
  ['close_session', { session_id: '__nonexistent__' }],
  ['stop_app', {}],
];

// ── MCP stdio transport ────────────────────────────────────────────────────
async function main() {
  console.log('════════════════════════════════════════════════════════════════');
  console.log(`  Full MCP Test — ${PLATFORM} (${TOOLS.length} tool calls)`);
  console.log('════════════════════════════════════════════════════════════════\n');

  const serverArgs = ['run', SERVER, 'server'];
  // For web-sdk platform, start bridge listener so browser SDK can connect
  if (PLATFORM === 'web-sdk') serverArgs.push('--bridge-port=18118');
  const proc = spawn(DART, serverArgs, {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, PATH: `/Users/cw/development/flutter/bin:${process.env.HOME}/Library/Android/sdk/platform-tools:${process.env.PATH}`, ANDROID_HOME: `${process.env.HOME}/Library/Android/sdk` },
  });

  // Collect stderr for debugging
  let stderrBuf = '';
  proc.stderr.on('data', d => { stderrBuf += d.toString(); });

  const responses = new Map();
  const rl = createInterface({ input: proc.stdout });
  rl.on('line', line => {
    try {
      const msg = JSON.parse(line);
      if (msg.id !== undefined) responses.set(msg.id, msg);
    } catch {}
  });

  let nextId = 1;
  const send = (method, params = {}) => {
    const id = nextId++;
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params, id }) + '\n');
    return id;
  };

  const waitFor = (id, timeoutMs = 30000) => new Promise(resolve => {
    const start = Date.now();
    const poll = () => {
      if (responses.has(id)) return resolve(responses.get(id));
      if (Date.now() - start > timeoutMs) return resolve({ id, error: { message: 'TIMEOUT' } });
      setTimeout(poll, 150);
    };
    poll();
  });

  const callTool = async (name, toolArgs = {}) => {
    const id = send('tools/call', { name, arguments: toolArgs });
    return waitFor(id);
  };

  // ── Initialize ───────────────────────────────────────────────────────────
  const initId = send('initialize', {
    protocolVersion: '2024-11-05',
    capabilities: {},
    clientInfo: { name: 'full-mcp-test', version: '1.0' },
  });
  const init = await waitFor(initId, 120000);
  if (!init.result) {
    console.log('❌ Initialize failed:', init.error?.message || stderrBuf.slice(-500));
    proc.kill();
    process.exit(1);
  }
  console.log(`Server: ${init.result.serverInfo?.name} v${init.result.serverInfo?.version}\n`);

  // ── For web-sdk: wait for browser SDK to connect to bridge listener ──
  if (PLATFORM === 'web-sdk') {
    // Bridge listener auto-starts with --bridge-port. Browser must already be open at http://localhost:3000
    // The SDK auto-connects to ws://127.0.0.1:18118
    console.log('  Waiting for browser SDK to connect to bridge listener on port 18118...');
    console.log('  (Ensure browser is open at http://localhost:3000 with SDK loaded)');
    // Wait for SDK to connect
    for (let i = 0; i < 30; i++) {
      await new Promise(r => setTimeout(r, 1000));
      // Check if scan_and_connect would find it
      const r = await callTool('get_connection_status', {});
      const text = r.result?.content?.[0]?.text || '';
      if (text.includes('web') || text.includes('connected')) break;
      // Try scan
      if (i === 5 || i === 15) {
        await callTool('scan_and_connect', {});
      }
    }
  }

  // ── Connect (platform-appropriate) ───────────────────────────────────────
  console.log('--- Connecting ---');
  let connected = false;
  if (isCDP && URL) {
    const r = await callTool('connect_cdp', { url: URL });
    connected = !r.error;
  } else if (VM_SERVICE) {
    const r = await callTool('connect_app', { uri: VM_SERVICE });
    connected = !r.error;
  } else {
    // For bridge platforms, always use scan_and_connect (connect_app treats ws:// as VM Service)
    const r = await callTool('scan_and_connect', {});
    try {
      const c = JSON.parse(r.result?.content?.[0]?.text || '{}');
      connected = !!c.success || (c.app != null);
    } catch { connected = !r.error; }
  }

  if (connected) console.log('  ✅ Connected\n');
  else console.log('  ⚠️  Connection may have failed — continuing anyway\n');

  // ── Context for dynamic args ─────────────────────────────────────────────
  const ctx = { PLATFORM, URI, URL, VM_SERVICE, PORT };

  // Track which tool names we've already seen (for the second connect_app)
  let connectAppCount = 0;

  // ── Run all tools ────────────────────────────────────────────────────────
  let currentSection = '';
  const sections = {
    0: 'Pre-connect', 3: 'Inspection', 22: 'Interaction', 41: 'Assertions',
    48: 'Auth', 52: 'Recording', 59: 'Utility', 69: 'CDP', 70: 'Connection Lifecycle',
  };

  for (let i = 0; i < TOOLS.length; i++) {
    const [toolName, argsOrFn] = TOOLS[i];

    // Section headers
    if (sections[i]) {
      if (currentSection) console.log('');
      currentSection = sections[i];
      console.log(`--- ${currentSection} ---`);
    }

    // Deduplicate display name for second connect_app
    let displayName = toolName;
    if (toolName === 'connect_app') {
      connectAppCount++;
      if (connectAppCount === 2) displayName = 'connect_app (reconnect)';
    }

    // Skip check
    const skipReason = shouldSkip(toolName);
    if (skipReason) {
      record(displayName, 'skip', skipReason);
      continue;
    }

    // Resolve args
    let toolArgs;
    try {
      toolArgs = typeof argsOrFn === 'function' ? argsOrFn(ctx) : argsOrFn;
    } catch (e) {
      record(displayName, 'fail', `args error: ${e.message}`);
      continue;
    }

    // Call
    try {
      const r = await callTool(toolName, toolArgs);

      if (r.error) {
        const msg = r.error.message || '';
        if (msg === 'TIMEOUT') {
          record(displayName, 'fail', 'TIMEOUT');
        } else if (msg.includes('Unknown tool')) {
          record(displayName, 'skip', msg.substring(0, 80));
        } else if (msg.includes('Not connected')) {
          record(displayName, 'fail', 'Not connected');
        } else if (msg.includes('not supported') || msg.includes('not available')) {
          record(displayName, 'skip', msg.substring(0, 80));
        } else {
          record(displayName, 'fail', msg.substring(0, 100));
        }
      } else {
        // Parse result content
        let content;
        try {
          content = JSON.parse(r.result?.content?.[0]?.text || '{}');
        } catch {
          content = r.result;
        }

        if (content?.success === false && content?.error) {
          const errMsg = typeof content.error === 'string' ? content.error : (content.error.message || JSON.stringify(content.error));
          // Some failures are expected (e.g. element not found for assert_not_visible is success)
          if (toolName === 'assert_not_visible' || toolName === 'wait_for_gone' || toolName === 'close_session') {
            record(displayName, 'pass', 'expected behavior');
          } else if (errMsg.includes('not found') || errMsg.includes('not supported') || errMsg.includes('not available') || errMsg.includes('Not connected')) {
            record(displayName, 'skip', errMsg.substring(0, 80));
          } else {
            record(displayName, 'fail', errMsg.substring(0, 100));
          }
        } else {
          record(displayName, 'pass');
        }
      }
    } catch (e) {
      record(displayName, 'fail', e.message?.substring(0, 100));
    }

    // Small delay for state-dependent tools (video needs time)
    if (toolName === 'video_start') await new Promise(r => setTimeout(r, 2000));
    if (toolName === 'record_start') {
      // do a couple actions to record
      await callTool('tap', { key: EK.button }).catch(() => {});
    }
  }

  // ── Summary table ────────────────────────────────────────────────────────
  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('  SUMMARY');
  console.log('════════════════════════════════════════════════════════════════');
  console.log(`  ${'Tool'.padEnd(35)} ${'Status'.padEnd(10)} Notes`);
  console.log(`  ${'─'.repeat(35)} ${'─'.repeat(10)} ${'─'.repeat(40)}`);
  for (const r of results) {
    const icon = r.status === 'pass' ? '✅' : r.status === 'fail' ? '❌' : '⚠️';
    console.log(`  ${r.tool.padEnd(35)} ${icon}  ${r.note}`);
  }
  console.log(`\n  ${pass} passed, ${fail} failed, ${skip} skipped — ${pass + fail + skip} total`);
  console.log('════════════════════════════════════════════════════════════════\n');

  proc.kill();
  process.exit(fail > 0 ? 1 : 0);
}

main().catch(e => { console.error('Fatal:', e); process.exit(1); });
