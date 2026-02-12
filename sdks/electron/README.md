# Flutter Skill — Electron SDK

AI E2E testing bridge for Electron apps. Exposes a JSON-RPC 2.0 WebSocket server on port 18118.

## Install

```bash
npm install flutter-skill-electron
```

## Usage (Main Process)

```js
const { FlutterSkillElectron } = require('flutter-skill-electron');
const bridge = new FlutterSkillElectron({ window: mainWindow });
bridge.start();
```

## Preload (Optional)

```js
new BrowserWindow({
  webPreferences: { preload: require.resolve('flutter-skill-electron/preload') }
});
```

## Supported Commands

`health`, `inspect`, `tap`, `enter_text`, `screenshot`, `scroll`, `get_text`, `find_element`, `wait_for_element`

All via JSON-RPC 2.0 over WebSocket on port 18118.
