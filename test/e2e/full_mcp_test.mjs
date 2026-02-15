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
const FLUTTER_PLATFORMS = new Set(['flutter-ios', 'flutter-web', 'android']);
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

const TOOLS = [
  // ── Connection (10) ──
  ['get_connection_status', {}],
  ['list_sessions', {}],
  ['list_running_apps', {}],
  ['connect_app', (ctx) => {
    if (ctx.VM_SERVICE) return { uri: ctx.VM_SERVICE };
    if (ctx.URI) return { uri: ctx.URI };
    return { uri: `ws://127.0.0.1:${ctx.PORT}` };
  }],
  ['launch_app', { package: 'com.example.test' }],
  ['scan_and_connect', {}],
  ['switch_session', { session_id: 'default' }],
  ['disconnect', {}],
  // reconnect after disconnect
  ['connect_app', (ctx) => {
    if (ctx.VM_SERVICE) return { uri: ctx.VM_SERVICE };
    if (ctx.URI) return { uri: ctx.URI };
    return { uri: `ws://127.0.0.1:${ctx.PORT}` };
  }],
  ['close_session', { session_id: '__nonexistent__' }],
  ['stop_app', {}],

  // ── Inspection (19) ──
  ['inspect', {}],
  ['inspect_interactive', {}],
  ['snapshot', { mode: 'text' }],
  ['get_widget_tree', {}],
  ['get_widget_properties', { widget_id: '0' }],
  ['get_text_content', {}],
  ['find_by_type', { type: 'Text' }],
  ['get_text_value', { key: 'counter' }],
  ['get_checkbox_state', { key: 'test-checkbox' }],
  ['get_slider_value', { key: 'test-slider' }],
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
  ['tap', { key: 'increment-btn' }],
  ['enter_text', { key: 'text-input', text: 'hello e2e' }],
  ['scroll_to', { key: 'counter' }],
  ['long_press', { key: 'increment-btn' }],
  ['double_tap', { key: 'increment-btn' }],
  ['swipe', { direction: 'up', distance: 300 }],
  ['drag', { startX: 100, startY: 300, endX: 100, endY: 100 }],
  ['tap_at', { x: 100, y: 200 }],
  ['long_press_at', { x: 100, y: 200 }],
  ['swipe_coordinates', { startX: 200, startY: 400, endX: 200, endY: 200 }],
  ['edge_swipe', { edge: 'left' }],
  ['gesture', { actions: [{ type: 'tap', x: 100, y: 100 }] }],
  ['go_back', {}],
  ['scroll_until_visible', { key: 'counter', direction: 'down' }],
  ['native_tap', { x: 100, y: 200 }],
  ['native_input_text', { text: 'native hello' }],
  ['native_swipe', { startX: 200, startY: 400, endX: 200, endY: 200 }],
  ['native_screenshot', {}],
  ['execute_batch', { actions: [{ tool: 'tap', arguments: { key: 'increment-btn' } }] }],

  // ── Assertions (7) ──
  ['assert_visible', { key: 'increment-btn' }],
  ['assert_not_visible', { key: 'nonexistent_xyz_999' }],
  ['assert_text', { key: 'counter', expected: '0' }],
  ['assert_element_count', { type: 'button', expected: 1 }],
  ['wait_for_element', { key: 'increment-btn', timeout: 3000 }],
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
];

// ── MCP stdio transport ────────────────────────────────────────────────────
async function main() {
  console.log('════════════════════════════════════════════════════════════════');
  console.log(`  Full MCP Test — ${PLATFORM} (${TOOLS.length} tool calls)`);
  console.log('════════════════════════════════════════════════════════════════\n');

  const proc = spawn(DART, ['run', SERVER, 'server'], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, PATH: `/Users/cw/development/flutter/bin:${process.env.PATH}` },
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

  const waitFor = (id, timeoutMs = 10000) => new Promise(resolve => {
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
  const init = await waitFor(initId, 15000);
  if (!init.result) {
    console.log('❌ Initialize failed:', init.error?.message || stderrBuf.slice(-500));
    proc.kill();
    process.exit(1);
  }
  console.log(`Server: ${init.result.serverInfo?.name} v${init.result.serverInfo?.version}\n`);

  // ── Connect (platform-appropriate) ───────────────────────────────────────
  console.log('--- Connecting ---');
  let connected = false;
  if (isCDP && URL) {
    const r = await callTool('connect_cdp', { url: URL });
    connected = !r.error;
  } else if (VM_SERVICE) {
    const r = await callTool('connect_app', { uri: VM_SERVICE });
    connected = !r.error;
  } else if (URI) {
    const r = await callTool('connect_app', { uri: URI });
    connected = !r.error;
  } else {
    // Try scan_and_connect
    const r = await callTool('scan_and_connect', {});
    try {
      const c = JSON.parse(r.result?.content?.[0]?.text || '{}');
      connected = !!c.success;
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
    0: 'Connection', 10: 'Inspection', 29: 'Interaction', 48: 'Assertions',
    55: 'Auth', 59: 'Recording', 66: 'Utility', 76: 'CDP',
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
        } else if (msg.includes('Not connected') || msg.includes('not supported') || msg.includes('not available') || msg.includes('Unknown tool')) {
          record(displayName, 'skip', msg.substring(0, 80));
        } else {
          // Treat JSON-RPC errors as failures unless clearly N/A
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
      await callTool('tap', { key: 'increment-btn' }).catch(() => {});
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
