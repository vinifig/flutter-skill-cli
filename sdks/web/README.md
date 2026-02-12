# flutter-skill Web SDK

Lightweight in-browser bridge that lets [flutter-skill](https://github.com/ai-dashboad/flutter-skill) automate **any web app** — React, Vue, Svelte, plain HTML, or any other framework.

## Quick Start

Add the script to your page during development:

```html
<script src="https://unpkg.com/flutter-skill@latest/web/flutter-skill.js"></script>
```

Or install via npm and import conditionally:

```bash
npm install flutter-skill
```

```js
// Only load in development
if (process.env.NODE_ENV === 'development') {
  require('flutter-skill/web');
}
```

## How It Works

1. **Include the SDK** in your web app (see above).
2. **Launch Chrome** with remote debugging enabled:
   ```bash
   # macOS
   /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
     --remote-debugging-port=9222 --user-data-dir=/tmp/chrome-debug

   # Linux
   google-chrome --remote-debugging-port=9222 --user-data-dir=/tmp/chrome-debug
   ```
3. **Open your app** in the browser.
4. **Run flutter-skill server** — it will auto-discover the web app via bridge discovery.
5. Use `scan_and_connect`, `inspect`, `tap`, `screenshot`, etc. as usual.

## Supported Methods

| Method | Description |
|--------|-------------|
| `inspect` | List interactive DOM elements with positions |
| `tap` | Click an element by key, text, or selector |
| `enter_text` | Type into an input/textarea |
| `swipe` | Simulate swipe gesture via pointer events |
| `scroll` | Scroll window or element |
| `find_element` | Check if an element exists |
| `get_text` | Get text content or input value |
| `wait_for_element` | Check element presence (proxy polls) |
| `screenshot` | Captured via CDP (handled by proxy) |
| `get_logs` | Retrieve captured console output |
| `clear_logs` | Clear log buffer |

## Element Selectors

Elements are found by (in priority order):

1. **`selector`** — any CSS selector (`#id`, `.class`, `button[type=submit]`)
2. **`key`** — matches `data-testid` attribute or element `id`
3. **`text`** — matches visible text content

## Architecture

```
flutter-skill server
      │
      ▼  (bridge WebSocket, port 18118)
WebBridgeProxy
      │
      ▼  (CDP WebSocket, port 9222)
Chrome browser
      │
      ▼  (in-page JS)
flutter-skill.js  →  window.__FLUTTER_SKILL_CALL__()
```

The proxy translates JSON-RPC bridge calls into CDP `Runtime.evaluate` calls that invoke the in-page SDK. Screenshots are taken directly via CDP `Page.captureScreenshot`.
