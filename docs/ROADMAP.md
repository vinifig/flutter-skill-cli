# Flutter Skill Roadmap

> AI-Powered End-to-End Testing for Flutter Apps — evolving toward a fully automated QA platform.

---

## Delivered

### v0.7.1 — Core Bug Fixes & README Rewrite
- **Screenshot after navigation**: Fixed stale screenshots by capturing from RenderView layer instead of first RepaintBoundary
- **enter_text without key**: Properly focuses the current text field when no key is specified
- **assert_text on buttons**: Now searches full widget tree including button children
- **Session auto-switch**: Automatically switches to the correct session when multiple apps are connected
- **inspect current_page_only**: Filters to show only the current route's elements (not the full Navigator stack)
- **screenshot_region save_to_file**: Region screenshots can now be saved to disk
- **Network monitoring**: New `get_network_requests` tool to capture HTTP traffic
- **README rewrite**: Repositioned as an AI E2E testing tool with clear quick-start guide

### v0.7.2 — Stability Fix
- **JSON-RPC type casting**: Fixed `get_errors` and `get_network_requests` parameter parsing (integers sent as strings)

### v0.7.3 — Native Platform Interaction
- **native_screenshot**: OS-level screenshots via `xcrun simctl` (iOS) and `adb screencap` (Android)
- **native_tap**: macOS Accessibility API for iOS Simulator, `adb input tap` for Android
- **native_input_text**: Pasteboard + Cmd+V for iOS, `adb input text` for Android
- **native_swipe**: Accessibility scroll actions for iOS, `adb input swipe` for Android
- **Hybrid detection**: Seamless fallback from VM Service to native driver when native views are presented
- **Release script fix**: Prevented duplicate CHANGELOG entries

---

## Phase 1: IDE Panel Integration (v0.7.4)

### VSCode Extension — Test Explorer Panel
- Sidebar tree view: discover `.test.md` files in project
- Run/Stop buttons per test file and per test case
- Real-time status indicators (running, passed, failed, skipped)
- Inline screenshot previews on test step click
- Error details with failure screenshots
- Test history and one-click re-run

### IntelliJ Plugin — Test Tool Window
- Same features as VSCode, native IntelliJ UI
- Tool window with test tree, status, and screenshots
- Run configurations for `.test.md` files
- Gutter icons to run individual tests

### `.test.md` Format Specification
- Human-readable markdown test files, version-controllable
- `## Test: <name>` defines a test case
- Numbered steps map to MCP tool calls (`tap`, `enter_text`, `assert_visible`, etc.)
- Supports variables and setup/teardown sections

```markdown
<!-- login.test.md -->
# Login Flow

## Setup
- Launch app on device

## Test: Valid credentials
1. Enter "test@example.com" in email field
2. Enter "password123" in password field
3. Tap "Login"
4. Verify "Dashboard" appears

## Test: Empty password
1. Leave password empty
2. Tap "Login"
3. Verify "Password required" error appears
```

---

## Phase 2: `.test.md` Engine + MCP Tools (v0.7.5)

### `run_test_plan` MCP Tool
- Parse `.test.md` files into executable test steps
- Map natural language steps to MCP tool calls
- Return structured results: pass/fail per step, screenshots, error details
- Also accept inline plan: `run_test_plan({ plan: "Test login with valid credentials" })`

### AI Terminal Agent Experience (Claude Code, Gemini CLI)

The AI agent IS the test runner and dashboard — no extra UI needed.

```
Running login.test.md...

✅ Test: Valid credentials (3.2s)
   1. ✅ Entered email
   2. ✅ Entered password
   3. ✅ Tapped Login
   4. ✅ Dashboard appeared
   [screenshot]

❌ Test: Empty password (1.8s)
   1. ✅ Left password empty
   2. ✅ Tapped Login
   3. ❌ Expected "Password required" but found "Please enter password"
   [screenshot of failure]

Summary: 1/2 passed
```

### CI/CD Headless Runner
- `flutter-skill run-tests --plan login.test.md --device "iPhone 16" --output results.json`
- Structured JSON/JUnit XML output for CI integration
- Exit code 0/1 for pass/fail gating
- GitHub Actions / GitLab CI ready

---

## Phase 3: Smart Screenshots + Intelligent Waits (v0.7.6)

### Smart Screenshot Optimization
- Auto-compress screenshots for AI vision models (reduce token cost 3-5x)
- Configurable quality/resolution presets: `screenshot({ quality: "ai" })`
- Auto-crop status bar and navigation bar
- Delta screenshots (only send changed regions)

### Intelligent Wait System
- Replace fixed timeouts with smart polling: `wait_for_stable()` waits until UI stops changing
- Auto-detect animations/transitions and wait for completion
- Network-aware waiting (wait for HTTP requests to complete)

---

## Phase 4: Error Recovery + Semantic Discovery (v0.7.7)

### Enhanced Error Recovery
- Auto-reconnect on VM Service disconnection
- Graceful handling of app crashes with diagnostic info
- Retry logic for flaky operations (tap during animation, etc.)

### Semantic Element Discovery
- Find elements by semantic meaning: `find({ role: "submit_button" })` instead of exact key/text
- Fuzzy text matching: `tap({ text: "Submit" })` matches "SUBMIT", "Submit Order", etc.
- AI-friendly element descriptions in inspect output

---

## Phase 5: AI Test Generation + Parallel Execution (v0.7.8)

### AI Test Case Generation
- `generate_tests({ screen: "login" })` — AI analyzes the current screen and generates test cases
- Auto-detect form fields, buttons, and navigation paths
- Generate edge cases: empty fields, long text, special characters, boundary values
- Output as reusable `.test.md` files or structured JSON

### Parallel Test Execution
- Run multiple test sessions simultaneously on different simulators/emulators
- `run_parallel({ plans: [...], devices: ["iPhone 16", "Pixel 8"] })`
- Aggregate results across devices into a single report
- Detect device-specific failures

```
You: "Run login.test.md on iPhone 16 and Pixel 8"

┌──────────────────────┬──────────────────────┐
│ iPhone 16 Pro        │ Pixel 8              │
├──────────────────────┼──────────────────────┤
│ ✅ Valid login  3.2s │ ✅ Valid login  3.5s  │
│ ❌ Empty pass   1.8s │ ❌ Empty pass   2.1s  │
│ ✅ Long text    2.1s │ ✅ Long text    2.3s  │
├──────────────────────┼──────────────────────┤
│ 2/3 passed           │ 2/3 passed           │
└──────────────────────┴──────────────────────┘
```

---

## Phase 6: Live Recording + Streaming (v0.7.9)

### Live Test Recording & Replay
- `start_recording()` / `stop_recording()` — capture all interactions as a video/GIF
- Export test steps as replayable scripts (JSON or natural language)
- Visual diff: compare recorded runs to detect regressions
- Shareable test reports with screenshots at each step

### MCP Streaming Progress
- Real-time progress via MCP `notifications/progress`
- AI terminal agents receive live updates during test execution

```
⏳ Running 4 tests across 2 devices...

[iPhone 16] Test 1: Valid login     ✅ passed (3.2s)
[iPhone 16] Test 2: Empty password  ⏳ running... step 2/4
[Pixel 8]   Test 1: Valid login     ✅ passed (3.5s)
[Pixel 8]   Test 2: Empty password  ⏳ running... step 1/4

Progress: 2/8 complete ████░░░░░░ 25%
```

---

## Phase 7: Advanced Testing (v0.7.10)

### Visual Regression Testing
- `screenshot_compare({ baseline: "login_screen" })` — pixel-diff with threshold
- Auto-generate baselines on first run
- Highlight visual differences in returned image
- Golden file management (save/update/compare)

### Performance Monitoring Integration
- Frame rate tracking during interactions
- Memory usage snapshots before/after operations
- Jank detection and reporting
- Network request timing correlation

### Accessibility Validation
- `check_accessibility()` — verify semantic labels, contrast ratios, touch targets
- WCAG compliance checking
- Screen reader simulation output

---

## Phase 8: Multi-Framework Support (v0.7.11)

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
| **v0.7.1** | Bug Fixes | Screenshot fix, enter_text fix, assert_text fix, network monitoring |
| **v0.7.2** | Stability | JSON-RPC type cast fixes |
| **v0.7.3** | Native Platform | iOS/Android native view support, hybrid detection |
| **v0.7.4** | IDE Panels | VSCode test explorer, IntelliJ tool window, `.test.md` format |
| **v0.7.5** | Test Engine | `run_test_plan` MCP tool, `.test.md` parser, CI/CD runner |
| **v0.7.6** | Smart Core | Smart screenshots, intelligent waits |
| **v0.7.7** | Reliability | Error recovery, semantic element discovery |
| **v0.7.8** | AI QA | AI test generation, parallel multi-device execution |
| **v0.7.9** | Recording | Live test recording, MCP streaming progress |
| **v0.7.10** | Advanced Testing | Visual regression, performance monitoring, accessibility |
| **v0.7.11** | Multi-Framework | React Native, native iOS/Android, Web, Electron support |

---

## Priority Matrix

| Feature | Impact | Effort | Priority |
|---------|--------|--------|----------|
| IDE panel integration | High (DX) | Medium | P0 — next |
| `.test.md` engine | High (AI QA core) | Medium | P0 |
| Smart screenshots | High (token cost) | Low | P1 |
| Intelligent waits | High (reliability) | Medium | P1 |
| Error recovery | High (stability) | Medium | P1 |
| Semantic discovery | High (usability) | Medium | P1 |
| AI test case generation | High (AI QA vision) | High | P2 |
| Parallel test execution | High (speed) | High | P2 |
| Live test recording | Medium (DX) | Medium | P2 |
| Visual regression | Medium (testing) | Medium | P2 |
| React Native support | High (market) | High | P3 |
| Web support | Medium (market) | Medium | P3 |
| Accessibility | Medium (quality) | Low | P3 |
| Performance monitoring | Low (niche) | Medium | P3 |
| Electron support | Low (niche) | Low | P3 |
