/**
 * Complex React Native mock server simulating a social media app.
 * Supports multiple screens, rich UI, form state, scroll tracking, and semantic refs.
 * Backward-compatible with original element keys.
 */
import { createServer } from 'net';
import { createHash } from 'crypto';

const PORT = process.argv[2] || 18118;
const SDK_VERSION = '1.0.0';

// --- Simulated UI State ---
let counter = 0;
let inputText = '';
let currentScreen = 'home'; // home, search, create, profile, detail, item-detail
let scrollOffset = 0;
let logs = [];
let selectedItemIndex = null;
let darkMode = false;
let searchText = '';
let formState = { title: '', description: '', category: 'general', newsletter: false, notifications: true };
let profilePosts = ['My first post', 'Vacation photos', 'Recipe share', 'Book review', 'Workout log'];

function addLog(action, detail) {
  logs.push({ timestamp: Date.now(), action, detail, screen: currentScreen });
}

// --- Feed Data ---
const feedItems = [];
for (let i = 0; i < 25; i++) {
  feedItems.push({
    id: i,
    title: ['Sunset Photography', 'Morning Run', 'New Recipe', 'Travel Diary', 'Book Club',
            'Fitness Goals', 'Coffee Art', 'Street Style', 'Home Decor', 'Pet Corner',
            'Music Review', 'Tech News', 'Game Night', 'Art Gallery', 'Food Truck',
            'Beach Day', 'Mountain Hike', 'City Tour', 'Garden Tips', 'Movie Night',
            'Yoga Flow', 'Baking Fun', 'DIY Project', 'Concert Live', 'Weekend Vibes'][i],
    description: `Amazing content from user${i + 1} #trending`,
    likes: Math.floor(Math.random() * 1000) + 10,
    liked: false,
    author: `user${i + 1}`,
  });
}

const searchResults = [
  { key: 'result-0', title: 'Photography Tips', type: 'article' },
  { key: 'result-1', title: 'Best Cafes Nearby', type: 'place' },
  { key: 'result-2', title: 'Workout Plans', type: 'video' },
  { key: 'result-3', title: 'Cooking Masterclass', type: 'video' },
  { key: 'result-4', title: 'Travel Destinations 2025', type: 'article' },
  { key: 'result-5', title: 'Local Events', type: 'event' },
  { key: 'result-6', title: 'Book Recommendations', type: 'article' },
  { key: 'result-7', title: 'Music Playlist', type: 'audio' },
];

function el(type, key, text, bounds, extra = {}) {
  return { type, key, text, bounds, visible: true, enabled: true, clickable: type === 'button' || type === 'checkbox' || type === 'toggle' || extra.clickable || false, ...extra };
}

function buildElements() {
  const els = [];
  const b = (x, y, w = 300, h = 40) => ({ x, y, width: w, height: h });

  if (currentScreen === 'home') {
    // Nav bar
    els.push(el('button', 'nav-home', 'Home', b(0, 0, 90, 50), { clickable: true }));
    els.push(el('button', 'nav-search', 'Search', b(90, 0, 90, 50), { clickable: true }));
    els.push(el('button', 'nav-create', 'Create', b(180, 0, 90, 50), { clickable: true }));
    els.push(el('button', 'nav-profile', 'Profile', b(270, 0, 90, 50), { clickable: true }));

    // Backward-compat elements
    els.push(el('text', 'counter', `Count: ${counter}`, b(20, 60, 200)));
    els.push(el('button', 'increment-btn', 'Increment', b(20, 110, 120)));
    els.push(el('button', 'decrement-btn', 'Decrement', b(150, 110, 120)));
    els.push(el('text_field', 'text-input', inputText, b(20, 160, 250), { clickable: true }));
    els.push(el('button', 'submit-btn', 'Submit', b(280, 160, 80)));
    els.push(el('checkbox', 'test-checkbox', 'Toggle me', b(20, 210, 150)));
    els.push(el('button', 'detail-btn', 'Go to Detail', b(20, 260, 150)));

    // Feed items (visible based on scroll)
    const visibleStart = Math.floor(scrollOffset / 80);
    const visibleEnd = Math.min(visibleStart + 8, feedItems.length);
    for (let i = visibleStart; i < visibleEnd; i++) {
      const item = feedItems[i];
      const yBase = 320 + (i - visibleStart) * 80;
      els.push(el('text', `feed-title-${i}`, item.title, b(20, yBase, 280, 24)));
      els.push(el('text', `feed-desc-${i}`, item.description, b(20, yBase + 24, 280, 20)));
      els.push(el('button', `feed-like-${i}`, `♥ ${item.likes}`, b(300, yBase, 60, 30)));
      els.push(el('button', `feed-item-${i}`, 'View', b(300, yBase + 30, 60, 30)));
    }
    els.push(el('text', 'feed-count', `${feedItems.length} posts`, b(20, 960)));

  } else if (currentScreen === 'search') {
    els.push(el('button', 'nav-home', 'Home', b(0, 0, 90, 50)));
    els.push(el('text_field', 'search-input', searchText, b(20, 60, 300), { clickable: true }));
    els.push(el('text', 'text-input', inputText, b(-100, -100, 0, 0))); // hidden compat
    els.push(el('toggle', 'filter-photos', 'Photos', b(20, 110, 80, 30)));
    els.push(el('toggle', 'filter-videos', 'Videos', b(110, 110, 80, 30)));
    els.push(el('toggle', 'filter-articles', 'Articles', b(200, 110, 80, 30)));
    els.push(el('toggle', 'dark-mode-toggle', 'Dark Mode', b(290, 110, 80, 30)));

    const filtered = searchText
      ? searchResults.filter(r => r.title.toLowerCase().includes(searchText.toLowerCase()))
      : searchResults;
    for (const r of filtered) {
      els.push(el('button', r.key, r.title, b(20, 160 + filtered.indexOf(r) * 50, 320, 40)));
    }
    // Compat keys
    els.push(el('text', 'counter', `Count: ${counter}`, b(-100, -100, 0, 0)));
    els.push(el('button', 'increment-btn', 'Increment', b(-100, -100, 0, 0)));
    els.push(el('button', 'submit-btn', 'Submit', b(-100, -100, 0, 0)));
    els.push(el('checkbox', 'test-checkbox', 'Toggle me', b(-100, -100, 0, 0)));
    els.push(el('button', 'detail-btn', 'Go to Detail', b(-100, -100, 0, 0)));

  } else if (currentScreen === 'create') {
    els.push(el('button', 'nav-home', 'Home', b(0, 0, 90, 50)));
    els.push(el('text', 'create-header', 'Create Post', b(20, 60, 300, 40)));
    els.push(el('text_field', 'form-title', formState.title, b(20, 110, 320), { clickable: true }));
    els.push(el('text_field', 'form-description', formState.description, b(20, 160, 320, 80), { clickable: true }));
    els.push(el('dropdown', 'form-category', formState.category, b(20, 250, 320)));
    els.push(el('checkbox', 'form-newsletter', `Newsletter: ${formState.newsletter ? 'on' : 'off'}`, b(20, 300, 200)));
    els.push(el('toggle', 'form-notifications', `Notifications: ${formState.notifications ? 'on' : 'off'}`, b(20, 340, 200)));
    els.push(el('button', 'form-submit', 'Publish', b(20, 400, 320)));
    els.push(el('button', 'form-draft', 'Save Draft', b(20, 450, 150)));
    els.push(el('button', 'form-discard', 'Discard', b(180, 450, 150)));
    // Compat keys
    els.push(el('text_field', 'text-input', inputText, b(-100, -100, 0, 0), { clickable: true }));
    els.push(el('text', 'counter', `Count: ${counter}`, b(-100, -100, 0, 0)));
    els.push(el('button', 'increment-btn', 'Increment', b(-100, -100, 0, 0)));
    els.push(el('button', 'submit-btn', 'Submit', b(-100, -100, 0, 0)));
    els.push(el('checkbox', 'test-checkbox', 'Toggle me', b(-100, -100, 0, 0)));
    els.push(el('button', 'detail-btn', 'Go to Detail', b(-100, -100, 0, 0)));

  } else if (currentScreen === 'profile') {
    els.push(el('button', 'nav-home', 'Home', b(0, 0, 90, 50)));
    els.push(el('text', 'profile-name', 'Jane Doe', b(20, 60, 200)));
    els.push(el('text', 'profile-bio', 'Photographer & Traveler ✈️', b(20, 100, 300)));
    els.push(el('text', 'profile-followers', 'Followers: 1,234', b(20, 140)));
    els.push(el('text', 'profile-following', 'Following: 567', b(180, 140)));
    els.push(el('text', 'profile-posts-count', `Posts: ${profilePosts.length}`, b(20, 180)));
    els.push(el('button', 'profile-edit', 'Edit Profile', b(20, 220, 150)));
    els.push(el('button', 'profile-settings', 'Settings', b(180, 220, 150)));
    els.push(el('toggle', 'profile-dark-mode', `Dark Mode: ${darkMode ? 'on' : 'off'}`, b(20, 270, 200)));
    els.push(el('toggle', 'profile-private', 'Private Account', b(20, 310, 200)));
    for (let i = 0; i < profilePosts.length; i++) {
      els.push(el('text', `profile-post-${i}`, profilePosts[i], b(20, 360 + i * 40, 320)));
    }
    // Compat keys
    els.push(el('text_field', 'text-input', inputText, b(-100, -100, 0, 0), { clickable: true }));
    els.push(el('text', 'counter', `Count: ${counter}`, b(-100, -100, 0, 0)));
    els.push(el('button', 'increment-btn', 'Increment', b(-100, -100, 0, 0)));
    els.push(el('button', 'submit-btn', 'Submit', b(-100, -100, 0, 0)));
    els.push(el('checkbox', 'test-checkbox', 'Toggle me', b(-100, -100, 0, 0)));
    els.push(el('button', 'detail-btn', 'Go to Detail', b(-100, -100, 0, 0)));

  } else if (currentScreen === 'detail') {
    els.push(el('text', 'detail-title', 'Detail Page', b(20, 100, 300)));
    els.push(el('text', 'detail-counter', `Counter: ${counter}`, b(20, 150, 200, 30)));
    els.push(el('button', 'back-btn', 'Go Back', b(20, 200, 100)));
    // Compat
    els.push(el('text_field', 'text-input', inputText, b(-100, -100, 0, 0), { clickable: true }));
    els.push(el('text', 'counter', `Count: ${counter}`, b(-100, -100, 0, 0)));
    els.push(el('button', 'increment-btn', 'Increment', b(-100, -100, 0, 0)));
    els.push(el('button', 'submit-btn', 'Submit', b(-100, -100, 0, 0)));
    els.push(el('checkbox', 'test-checkbox', 'Toggle me', b(-100, -100, 0, 0)));
    els.push(el('button', 'detail-btn', 'Go to Detail', b(-100, -100, 0, 0)));

  } else if (currentScreen === 'item-detail') {
    const item = feedItems[selectedItemIndex] || feedItems[0];
    els.push(el('text', 'item-title', item.title, b(20, 60, 320)));
    els.push(el('text', 'item-author', `By ${item.author}`, b(20, 110)));
    els.push(el('text', 'item-desc', item.description, b(20, 150, 320, 60)));
    els.push(el('text', 'item-likes', `${item.likes} likes`, b(20, 220)));
    els.push(el('button', 'item-like-btn', item.liked ? 'Unlike' : 'Like', b(20, 260, 100)));
    els.push(el('button', 'item-share', 'Share', b(130, 260, 100)));
    els.push(el('button', 'item-save', 'Save', b(240, 260, 100)));
    els.push(el('text_field', 'item-comment', '', b(20, 320, 260), { clickable: true }));
    els.push(el('button', 'item-post-comment', 'Post', b(290, 320, 70)));
    els.push(el('button', 'back-btn', 'Go Back', b(20, 380, 100)));
    // Compat
    els.push(el('text_field', 'text-input', inputText, b(-100, -100, 0, 0), { clickable: true }));
    els.push(el('text', 'counter', `Count: ${counter}`, b(-100, -100, 0, 0)));
    els.push(el('button', 'increment-btn', 'Increment', b(-100, -100, 0, 0)));
    els.push(el('button', 'submit-btn', 'Submit', b(-100, -100, 0, 0)));
    els.push(el('checkbox', 'test-checkbox', 'Toggle me', b(-100, -100, 0, 0)));
    els.push(el('button', 'detail-btn', 'Go to Detail', b(-100, -100, 0, 0)));
  }

  return els;
}

function findByKey(key) { return buildElements().find(e => e.key === key); }
function findByText(text) { return buildElements().find(e => e.text && e.text.includes(text)); }
function findByRef(ref) {
  // ref format: "type:Key_Name" -> find by key mapping
  const elements = buildElements();
  return elements.find(e => makeRef(e) === ref) || null;
}

function makeRef(el) {
  const typeMap = { button: 'button', text_field: 'input', text: 'text', checkbox: 'checkbox', toggle: 'toggle', dropdown: 'dropdown' };
  const prefix = typeMap[el.type] || el.type;
  const name = (el.text || el.key).replace(/[^a-zA-Z0-9]/g, '_').replace(/_+/g, '_').replace(/^_|_$/g, '');
  return `${prefix}:${name}`;
}

// --- JSON-RPC Methods ---
const methods = {
  initialize: () => ({ success: true, framework: 'react-native', sdk_version: SDK_VERSION, platform: 'node-test' }),

  inspect: () => ({ elements: buildElements() }),

  inspect_interactive: () => {
    const elements = buildElements();
    const interactive = elements.map((el, i) => {
      const actions = [];
      if (el.clickable) actions.push('tap');
      if (el.type === 'text_field') actions.push('tap', 'enter_text');
      if (el.type === 'toggle' || el.type === 'checkbox') actions.push('tap', 'toggle');
      return {
        ...el,
        ref: makeRef(el),
        actions,
        index: i,
        xpath: `//*[@key='${el.key}']`,
        interactable: actions.length > 0,
      };
    });
    return { elements: interactive, interactiveMode: true, refFormat: 'semantic', totalElements: elements.length };
  },

  tap: (p) => {
    let key = p.key || p.selector;
    if (key && key.startsWith('ref:')) key = key.substring(4);

    // Find element by ref, key, or text
    let el = null;
    if (p.ref) el = findByRef(p.ref);
    if (!el && key) el = findByKey(key);
    if (!el && p.text) el = findByText(p.text);
    if (!el && p.x != null) {
      // coordinate tap - find element at position
      const elements = buildElements();
      el = elements.find(e => {
        const b = e.bounds;
        return p.x >= b.x && p.x <= b.x + b.width && p.y >= b.y && p.y <= b.y + b.height;
      });
      if (!el) return { success: true, message: 'No element at coordinates' };
    }
    if (!el) return { success: false, message: 'Element not found' };

    addLog('tap', el.key);

    // Navigation
    if (el.key === 'nav-home') { currentScreen = 'home'; scrollOffset = 0; }
    else if (el.key === 'nav-search') { currentScreen = 'search'; }
    else if (el.key === 'nav-create') { currentScreen = 'create'; }
    else if (el.key === 'nav-profile') { currentScreen = 'profile'; }
    else if (el.key === 'detail-btn') { currentScreen = 'detail'; }
    else if (el.key === 'back-btn') { currentScreen = 'home'; scrollOffset = 0; }
    // Feed actions
    else if (el.key?.startsWith('feed-item-')) {
      selectedItemIndex = parseInt(el.key.split('-')[2]);
      currentScreen = 'item-detail';
    }
    else if (el.key?.startsWith('feed-like-')) {
      const idx = parseInt(el.key.split('-')[2]);
      feedItems[idx].liked = !feedItems[idx].liked;
      feedItems[idx].likes += feedItems[idx].liked ? 1 : -1;
    }
    // Counter
    else if (el.key === 'increment-btn') { counter++; }
    else if (el.key === 'decrement-btn') { counter--; }
    // Item detail
    else if (el.key === 'item-like-btn' && selectedItemIndex != null) {
      feedItems[selectedItemIndex].liked = !feedItems[selectedItemIndex].liked;
      feedItems[selectedItemIndex].likes += feedItems[selectedItemIndex].liked ? 1 : -1;
    }
    // Profile toggles
    else if (el.key === 'profile-dark-mode' || el.key === 'dark-mode-toggle') { darkMode = !darkMode; }
    // Form
    else if (el.key === 'form-newsletter') { formState.newsletter = !formState.newsletter; }
    else if (el.key === 'form-notifications') { formState.notifications = !formState.notifications; }

    return { success: true };
  },

  enter_text: (p) => {
    let key = p.key || p.selector;
    if (p.ref) {
      const el = findByRef(p.ref);
      if (el) key = el.key;
    }
    const el = key ? findByKey(key) : null;
    if (!el) return { success: false, message: 'Not found' };
    addLog('enter_text', `${key}: "${(p.text || '').slice(0, 50)}"`);

    if (key === 'text-input') inputText = p.text || '';
    else if (key === 'search-input') searchText = p.text || '';
    else if (key === 'form-title') formState.title = p.text || '';
    else if (key === 'form-description') formState.description = p.text || '';
    else inputText = p.text || '';

    return { success: true };
  },

  get_text: (p) => {
    let key = p.key || p.selector;
    if (p.ref) {
      const el = findByRef(p.ref);
      if (el) key = el.key;
    }
    const el = key ? findByKey(key) : null;
    if (!el) return { text: null };

    if (key === 'text-input') return { text: inputText };
    if (key === 'search-input') return { text: searchText };
    if (key === 'form-title') return { text: formState.title };
    if (key === 'form-description') return { text: formState.description };
    return { text: el.text };
  },

  find_element: (p) => {
    let key = p.key || p.selector;
    if (key && key.startsWith('ref:')) key = key.substring(4);
    let el = null;
    if (p.ref) el = findByRef(p.ref);
    if (!el && key) el = findByKey(key);
    if (!el && p.text) el = findByText(p.text);
    if (el) return { found: true, element: { type: el.type, key: el.key, text: el.text }, bounds: el.bounds };
    return { found: false };
  },

  wait_for_element: (p) => {
    let key = p.key || p.selector;
    let el = null;
    if (p.ref) el = findByRef(p.ref);
    if (!el && key) el = findByKey(key);
    if (!el && p.text) el = findByText(p.text);
    return { found: !!el };
  },

  scroll: (p) => {
    const dist = p.distance || 300;
    if (p.direction === 'down') scrollOffset = Math.min(scrollOffset + dist, 2000);
    else if (p.direction === 'up') scrollOffset = Math.max(scrollOffset - dist, 0);
    addLog('scroll', `${p.direction} ${dist}px (offset: ${scrollOffset})`);
    return { success: true };
  },

  swipe: (p) => {
    addLog('swipe', `${p.direction} ${p.distance || 0}px`);
    return { success: true };
  },

  screenshot: () => {
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFklEQVQYV2P8z8BQz0BFwMgwasChAwA3vgX/EPGcywAAAABJRU5ErkJggg==';
    return { success: true, image: png, format: 'png', encoding: 'base64' };
  },

  go_back: () => {
    addLog('go_back', `from ${currentScreen}`);
    if (currentScreen !== 'home') { currentScreen = 'home'; scrollOffset = 0; return { success: true }; }
    return { success: true };
  },

  get_logs: () => ({ logs }),
  clear_logs: () => { logs = []; return { success: true }; },
};

function handleJsonRpc(raw) {
  let req;
  try { req = JSON.parse(raw); } catch { return JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }); }
  const fn = methods[req.method];
  if (!fn) return JSON.stringify({ jsonrpc: '2.0', id: req.id, error: { code: -32601, message: `Unknown: ${req.method}` } });
  try {
    const result = fn(req.params || {});
    return JSON.stringify({ jsonrpc: '2.0', id: req.id, result });
  } catch (e) {
    return JSON.stringify({ jsonrpc: '2.0', id: req.id, error: { code: -32000, message: e.message } });
  }
}

// --- WebSocket helpers ---
function decodeFrame(buf) {
  if (buf.length < 2) return null;
  const opcode = buf[0] & 0x0f;
  const masked = (buf[1] & 0x80) !== 0;
  let payloadLen = buf[1] & 0x7f;
  let offset = 2;
  if (payloadLen === 126) { if (buf.length < 4) return null; payloadLen = buf.readUInt16BE(2); offset = 4; }
  else if (payloadLen === 127) { if (buf.length < 10) return null; payloadLen = buf.readUInt32BE(6); offset = 10; }
  let maskKey;
  if (masked) { if (buf.length < offset + 4) return null; maskKey = buf.slice(offset, offset + 4); offset += 4; }
  if (buf.length < offset + payloadLen) return null;
  const payload = Buffer.alloc(payloadLen);
  for (let i = 0; i < payloadLen; i++) payload[i] = masked ? buf[offset + i] ^ maskKey[i % 4] : buf[offset + i];
  return { opcode, payload: payload.toString('utf-8'), totalBytes: offset + payloadLen };
}

function encodeFrame(text) {
  const data = Buffer.from(text, 'utf-8');
  const len = data.length;
  let header;
  if (len < 126) { header = Buffer.alloc(2); header[0] = 0x81; header[1] = len; }
  else if (len < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 126; header.writeUInt16BE(len, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 127; header.writeUInt32BE(0, 2); header.writeUInt32BE(len, 6); }
  return Buffer.concat([header, data]);
}

// --- TCP Server ---
const server = createServer((socket) => {
  let upgraded = false;
  let wsBuf = Buffer.alloc(0);

  socket.on('data', (data) => {
    if (upgraded) {
      wsBuf = Buffer.concat([wsBuf, data]);
      while (wsBuf.length > 0) {
        const frame = decodeFrame(wsBuf);
        if (!frame) break;
        wsBuf = wsBuf.slice(frame.totalBytes);
        if (frame.opcode === 0x08) { socket.destroy(); return; }
        if (frame.opcode === 0x01) {
          const resp = handleJsonRpc(frame.payload);
          socket.write(encodeFrame(resp));
        }
      }
      return;
    }

    const raw = data.toString('utf-8');
    const lines = raw.split('\r\n');
    const [method, path] = (lines[0] || '').split(' ');
    const headers = {};
    for (let i = 1; i < lines.length; i++) {
      if (lines[i] === '') break;
      const idx = lines[i].indexOf(':');
      if (idx > 0) headers[lines[i].slice(0, idx).trim().toLowerCase()] = lines[i].slice(idx + 1).trim();
    }

    if (headers['upgrade']?.toLowerCase() === 'websocket') {
      const wsKey = headers['sec-websocket-key'];
      const accept = createHash('sha1').update(wsKey + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
      upgraded = true;
      wsBuf = Buffer.alloc(0);
      return;
    }

    if (method === 'GET' && path === '/.flutter-skill') {
      const body = JSON.stringify({
        framework: 'react-native', app_name: 'Social Media App', platform: 'node-test',
        capabilities: Object.keys(methods), sdk_version: SDK_VERSION
      });
      socket.write(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`);
      socket.destroy();
      return;
    }

    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    socket.destroy();
  });

  socket.on('error', () => {});
});

server.listen(parseInt(PORT), '127.0.0.1', () => {
  console.log(`[flutter-skill-rn] Social media test app on port ${PORT}`);
});
