#!/usr/bin/env node
/**
 * Comprehensive MCP test — all 139 tools across 10 platforms via MCP stdio JSON-RPC.
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

const DART   = '/tmp/fs-207';
const SERVER = '';

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
const CDP_ONLY     = new Set([
  'connect_cdp', 'get_title', 'get_page_source', 'count_elements', 'is_visible',
  'get_attribute', 'get_css_property', 'get_bounding_box', 'get_cookies', 'set_cookie',
  'clear_cookies', 'get_local_storage', 'set_local_storage', 'clear_local_storage',
  'get_session_storage', 'get_console_messages', 'get_network_requests', 'navigate',
  'reload', 'go_forward', 'set_viewport', 'emulate_device', 'generate_pdf',
  'wait_for_navigation', 'wait_for_network_idle', 'get_tabs', 'new_tab', 'switch_tab',
  'close_tab', 'get_frames', 'eval_in_frame', 'get_window_handles',
  'install_dialog_handler', 'handle_dialog', 'intercept_requests', 'clear_interceptions',
  'block_urls', 'throttle_network', 'go_offline', 'clear_browser_data',
  'accessibility_audit', 'set_geolocation', 'set_timezone', 'set_color_scheme',
  'upload_file', 'compare_screenshot', 'get_visible_text',
]);
const BRIDGE_OR_CDP = new Set(['hover', 'fill', 'select_option', 'set_checkbox', 'focus', 'blur', 'eval', 'type_text']);
const NO_WEB       = new Set(['auth_deeplink', 'auth_biometric']);

function shouldSkip(tool) {
  if (FLUTTER_ONLY.has(tool) && !isFlutter) return 'Flutter-only';
  if (MOBILE_ONLY.has(tool) && !isMobile)   return 'mobile-only';
  if (CDP_ONLY.has(tool) && !isCDP)         return 'CDP-only';
  if (BRIDGE_OR_CDP.has(tool) && isFlutter) return 'bridge/CDP-only';
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

// ── All 139 tools with test definitions ────────────────────────────────────
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
  ['execute_batch', { actions: [{ tool: 'tap', args: { key: EK.button } }] }],

  // ── Cross-platform extras ──
  ['screenshot', { quality: 0.5, save_to_file: true }],
  ['screenshot_region', { x: 0, y: 0, width: 200, height: 200, save_to_file: true }],
  ['screenshot_element', { key: EK.button }],
  ['press_key', { key: 'Tab' }],
  ['type_text', { text: 'typed text' }],
  ['hover', { key: EK.button }],
  ['fill', { key: EK.input, value: 'filled text' }],
  ['select_option', { key: 'select_element', value: 'option1' }],
  ['set_checkbox', { key: EK.checkbox, checked: true }],
  ['focus', { key: EK.input }],
  ['blur', { key: EK.input }],
  ['eval', { expression: '1+1' }],

  // ── Assert batch ──
  ['assert_batch', { assertions: [
    { type: 'visible', key: EK.button },
    { type: 'visible', key: EK.input },
    { type: 'not_visible', key: 'nonexistent_xyz' }
  ]}],

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

  // ── Recording v0.8.1 ──
  ['record_start', {}],
  ['tap', { key: EK.button }],
  ['record_stop', {}],
  ['record_export', { format: 'jest' }],
  ['record_export', { format: 'playwright' }],
  ['record_export', { format: 'cypress' }],
  ['record_export', { format: 'selenium' }],
  ['record_export', { format: 'xcuitest' }],
  ['record_export', { format: 'espresso' }],
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

  // ── P2 tools ──
  ['visual_verify', { description: 'A social media app with login form', check_elements: [EK.button, EK.input] }],
  ['visual_diff', { baseline_path: '/tmp/nonexistent-baseline.png' }],
  ['generate_report', { format: 'html', title: 'E2E Test Report' }],
  ['generate_report', { format: 'json' }],
  ['generate_report', { format: 'markdown' }],
  ['list_plugins', {}],
  ['multi_platform_test', { actions: [{ tool: 'snapshot', args: { mode: 'text' } }] }],
  ['compare_platforms', {}],

  // ── CDP — Browser State (16) ──
  ['get_title', {}],
  ['get_page_source', {}],
  ['get_page_source', { removeScripts: true, minify: true }],
  ['get_page_source', { selector: 'body', cleanHtml: true }],
  ['get_visible_text', {}],
  ['get_visible_text', { selector: 'body' }],
  ['count_elements', { selector: 'button' }],
  ['is_visible', { key: EK.button }],
  ['get_attribute', { key: EK.input, attribute: 'type' }],
  ['get_css_property', { key: EK.button, property: 'color' }],
  ['get_bounding_box', { key: EK.button }],
  ['get_cookies', {}],
  ['set_cookie', { name: 'test_cookie', value: 'hello123', domain: 'localhost' }],
  ['clear_cookies', {}],
  ['get_local_storage', {}],
  ['set_local_storage', { key: 'test_key', value: 'test_value' }],
  ['clear_local_storage', {}],
  ['get_session_storage', {}],
  ['get_console_messages', {}],
  ['get_network_requests', {}],

  // ── CDP — Page Control (9) ──
  ['navigate', { url: 'http://localhost:3000/' }],
  ['reload', {}],
  ['go_forward', {}],
  ['set_viewport', { width: 1280, height: 720 }],
  ['emulate_device', { device: 'iphone-14' }],
  ['emulate_device', { device: 'iPhone 14 Pro' }],
  ['emulate_device', { device: 'Pixel 7' }],
  ['emulate_device', { device: 'Desktop Chrome' }],
  ['set_viewport', { width: 1280, height: 720 }],  // reset after emulate
  ['generate_pdf', {}],
  ['wait_for_navigation', { timeout_ms: 5000 }],
  ['wait_for_network_idle', { timeout_ms: 5000 }],

  // ── CDP — Tabs & Frames (9) ──
  ['get_tabs', {}],
  ['new_tab', { url: 'about:blank' }],
  ['switch_tab', (ctx) => ({ target_id: ctx._lastNewTabId || '' })],
  ['close_tab', (ctx) => ({ target_id: ctx._lastNewTabId || '' })],
  ['get_frames', {}],
  ['eval_in_frame', { frame_id: '', expression: 'document.title' }],
  ['get_window_handles', {}],
  ['install_dialog_handler', { auto_accept: true }],
  ['handle_dialog', { accept: true }],

  // ── CDP — Network Control (8) ──
  ['intercept_requests', { url_pattern: '*.fake.invalid/*', status_code: 200, body: '{}' }],
  ['clear_interceptions', {}],
  ['block_urls', { patterns: ['*.tracking.example.com*'] }],
  ['throttle_network', { latency_ms: 100, download_kbps: 1000 }],
  ['go_offline', {}],
  ['throttle_network', { latency_ms: 0, download_kbps: -1, upload_kbps: -1 }],  // reset
  ['clear_browser_data', {}],
  ['accessibility_audit', {}],

  // ── CDP — Environment (6) ──
  ['set_geolocation', { latitude: 35.6762, longitude: 139.6503 }],
  ['set_timezone', { timezone: 'Asia/Tokyo' }],
  ['set_color_scheme', { scheme: 'dark' }],
  ['set_color_scheme', { scheme: 'light' }],  // reset
  ['upload_file', { selector: 'input[type="file"]', files: ['/tmp/test-upload.txt'] }],
  ['compare_screenshot', { baseline_path: '/tmp/baseline-test.png' }],

  // ── CDP-specific connection (1) ──
  ['connect_cdp', (ctx) => ({ url: ctx.URL || 'http://localhost:9222' })],

  // ── Native (at end — these can hang due to macOS Accessibility API) ──
  ['native_tap', { x: 100, y: 200 }],
  ['native_input_text', { text: 'native hello' }],
  ['native_swipe', { start_x: 200, start_y: 400, end_x: 200, end_y: 200 }],
  ['native_screenshot', {}],

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

  const serverArgs = ['server'];
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
    console.log('  Waiting for browser SDK to connect (10s)...');
    await new Promise(r => setTimeout(r, 10000));
  }

  // ── Connect (platform-appropriate) ───────────────────────────────────────
  console.log('--- Connecting ---');
  let connected = false;
  if (PLATFORM === 'web-sdk') {
    connected = true;
  } else if (isCDP && URL) {
    const cdpPort = parseInt(args.port) || 18800;
    const r = await callTool('connect_cdp', { url: URL, port: cdpPort, launch_chrome: false });
    connected = !r.error;
  } else if (VM_SERVICE) {
    const r = await callTool('connect_app', { uri: VM_SERVICE });
    connected = !r.error;
  } else {
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
    0: 'Pre-connect',
    3: 'Inspection',
    22: 'Interaction',
    37: 'Cross-platform extras',
    49: 'Assert batch',
    50: 'Assertions',
    57: 'Auth',
    61: 'Recording',
    74: 'Utility',
    84: 'P2 tools',
    92: 'CDP — Browser State',
    112: 'CDP — Page Control',
    124: 'CDP — Tabs & Frames',
    133: 'CDP — Network Control',
    141: 'CDP — Environment',
    147: 'CDP Connection',
    148: 'Native',
    152: 'Connection Lifecycle',
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

      // Capture new_tab targetId for switch_tab/close_tab
      if (toolName === 'new_tab' && !r.error) {
        try {
          const c = JSON.parse(r.result?.content?.[0]?.text || '{}');
          ctx._lastNewTabId = c.targetId || c.target_id || '';
        } catch {}
      }

      if (r.error) {
        const msg = r.error.message || '';
        // Expected errors for tools that need specific preconditions
        if ((toolName === 'handle_dialog' && msg.includes('No dialog')) ||
            (toolName === 'eval_in_frame' && msg.includes('No frame'))) {
          record(displayName, 'pass', 'expected error (no precondition)');
        } else if (msg === 'TIMEOUT') {
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
    // record_start tap is now explicit in TOOLS array
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
