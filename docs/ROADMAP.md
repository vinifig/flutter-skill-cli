# Flutter Skill Roadmap

> Comprehensive optimization and multi-framework expansion plan for Flutter Skill as an AI E2E testing platform.

---

## Phase 1: Core Flutter Optimization (v0.7.1)

### Smart Screenshot Optimization
- Auto-compress screenshots for AI vision models (reduce token cost 3-5x)
- Configurable quality/resolution presets: `screenshot({ quality: "ai" })`
- Auto-crop status bar and navigation bar
- Delta screenshots (only send changed regions)

### Intelligent Wait System
- Replace fixed timeouts with smart polling: `wait_for_stable()` waits until UI stops changing
- Auto-detect animations/transitions and wait for completion
- Network-aware waiting (wait for HTTP requests to complete)

### Enhanced Error Recovery
- Auto-reconnect on VM Service disconnection
- Graceful handling of app crashes with diagnostic info
- Retry logic for flaky operations (tap during animation, etc.)

### Semantic Element Discovery
- Find elements by semantic meaning: `find({ role: "submit_button" })` instead of exact key/text
- Fuzzy text matching: `tap({ text: "Submit" })` matches "SUBMIT", "Submit Order", etc.
- AI-friendly element descriptions in inspect output

---

## Phase 2: Advanced Testing Features (v0.7.2)

### Visual Regression Testing
- `screenshot_compare({ baseline: "login_screen" })` - pixel-diff with threshold
- Auto-generate baselines on first run
- Highlight visual differences in returned image
- Golden file management (save/update/compare)

### Test Recording & Playback
- `start_recording()` / `stop_recording()` - record all interactions
- Export as reusable test script (Dart test, JSON, or natural language)
- Parameterized playback with variable substitution

### Performance Monitoring Integration
- Frame rate tracking during interactions
- Memory usage snapshots before/after operations
- Jank detection and reporting
- Network request timing correlation

### Accessibility Validation
- `check_accessibility()` - verify semantic labels, contrast ratios, touch targets
- WCAG compliance checking
- Screen reader simulation output

---

## Phase 3: Native Platform Interaction (v0.7.3)

### Native View Support (iOS Simulator)
- `native_screenshot` - `xcrun simctl io screenshot` for native dialogs (photo picker, permission dialogs)
- `native_tap` - macOS Accessibility API for tapping native UI elements
- `native_input_text` - `simctl pbcopy` + paste for text input in native views
- `native_swipe` - Accessibility API scroll actions for native scroll views

### Native View Support (Android Emulator)
- `native_screenshot` - `adb shell screencap` for native views
- `native_tap` - `adb shell input tap x y`
- `native_input_text` - `adb shell input text`
- `native_swipe` - `adb shell input swipe`

### Hybrid Detection
- Auto-detect when native view is presented (VM Service becomes unresponsive)
- Seamless fallback: try VM Service first, fall back to native driver
- Unified API - same `tap()` / `screenshot()` works for both Flutter and native

---

## Phase 4: Multi-Framework Support (v0.7.4)

### Architecture: Universal App Driver

```
AbstractAppDriver (interface)
├── FlutterDriver (existing - VM Service Protocol)
├── ReactNativeDriver (new - Chrome DevTools Protocol / Hermes)
├── NativeIOSDriver (new - XCTest / Accessibility API)
├── NativeAndroidDriver (new - UIAutomator / adb)
├── WebDriver (new - Chrome DevTools Protocol)
└── ElectronDriver (new - Chrome DevTools Protocol + Node.js)
```

### React Native Support
- **Protocol**: Chrome DevTools Protocol (CDP) via Hermes debugger
- **Connection**: `ws://localhost:8081/debugger-proxy` (Metro bundler)
- **UI Inspection**: React DevTools protocol for component tree
- **Actions**: CDP `Input.dispatchTouchEvent` / `Input.dispatchKeyEvent`
- **Screenshots**: CDP `Page.captureScreenshot`

### Native iOS Support
- **Protocol**: XCTest framework + Accessibility API
- **Connection**: `xcrun simctl` for simulator, `idevice` tools for physical devices
- **UI Inspection**: Accessibility tree traversal
- **Actions**: XCTest gestures or Accessibility API `AXPress`
- **Screenshots**: `xcrun simctl io screenshot`

### Native Android Support
- **Protocol**: UIAutomator2 + adb
- **Connection**: `adb` for emulator and physical devices
- **UI Inspection**: `uiautomator dump` for view hierarchy
- **Actions**: `adb shell input` for tap/swipe/text
- **Screenshots**: `adb shell screencap`

### Web App Support
- **Protocol**: Chrome DevTools Protocol (CDP)
- **Connection**: `ws://localhost:9222` (Chrome remote debugging)
- **UI Inspection**: DOM traversal via CDP
- **Actions**: CDP Input domain
- **Screenshots**: CDP `Page.captureScreenshot`

### Unified MCP Interface

All frameworks share the same MCP tool names:

| Tool | Flutter | React Native | Native iOS | Native Android | Web |
|------|---------|-------------|------------|---------------|-----|
| `connect_app` | VM Service | Metro/CDP | XCTest | adb | CDP |
| `screenshot` | VM Service | CDP | simctl/idevice | screencap | CDP |
| `tap` | Extension | CDP touch | Accessibility | input tap | CDP |
| `inspect` | Extension | React DevTools | Accessibility tree | uiautomator | DOM |
| `enter_text` | Extension | CDP key | Accessibility | input text | CDP |

### Auto-Detection

```
scan_and_connect()
  → Detect running apps across all frameworks
  → Return: [
      { framework: "flutter", uri: "ws://...:50000/ws", name: "MyFlutterApp" },
      { framework: "react-native", uri: "ws://...:8081/debugger-proxy", name: "MyRNApp" },
      { framework: "web", uri: "ws://...:9222", name: "localhost:3000" }
    ]
  → Connect to selected app with appropriate driver
```

---

## Version Summary

| Version | Focus | Key Deliverables |
|---------|-------|-----------------|
| **v0.7.1** | Core Flutter Optimization | Smart screenshots, intelligent waits, error recovery, semantic discovery |
| **v0.7.2** | Advanced Testing | Visual regression, test recording, performance monitoring, accessibility |
| **v0.7.3** | Native Platform Interaction | iOS/Android native view support, hybrid detection, unified API |
| **v0.7.4** | Multi-Framework | React Native, native iOS/Android, Web, Electron support |

---

## Priority Matrix

| Feature | Impact | Effort | Priority |
|---------|--------|--------|----------|
| Smart screenshots | High (token cost) | Low | P0 |
| Intelligent waits | High (reliability) | Medium | P0 |
| Error recovery | High (stability) | Medium | P0 |
| Semantic discovery | High (usability) | Medium | P1 |
| Native view support | High (coverage) | High | P1 |
| Visual regression | Medium (testing) | Medium | P1 |
| React Native support | High (market) | High | P2 |
| Web support | Medium (market) | Medium | P2 |
| Test recording | Medium (DX) | Medium | P2 |
| Accessibility | Medium (quality) | Low | P2 |
| Performance monitoring | Low (niche) | Medium | P3 |
| Electron support | Low (niche) | Low | P3 |
