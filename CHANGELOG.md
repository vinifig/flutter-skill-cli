## 0.2.14

**Testing Efficiency & Batch Operations**

### New MCP Tools
- `execute_batch` - Execute multiple actions in sequence (reduces round-trip latency)
- `tap_at` / `long_press_at` - Coordinate-based interactions
- `swipe_coordinates` - Swipe from one coordinate to another
- `scroll_until_visible` - Scroll until target element becomes visible
- `assert_visible` / `assert_not_visible` - Assert element visibility
- `assert_text` - Assert element text content (equals or contains)
- `assert_element_count` - Assert count of elements matching criteria
- `get_page_state` - Get complete page state snapshot
- `get_interactable_elements` - Get all interactable elements with suggested actions
- `get_frame_stats` - Frame rendering statistics
- `get_memory_stats` - Memory usage statistics

### Efficiency Improvements
- Batch operations reduce test execution time by 60%+
- Smart scroll eliminates manual scroll + check loops
- Built-in assertions simplify test validation

---

## 0.2.13

**Feature Parity & Developer Experience**

### New MCP Tools
- `scan_and_connect` - Auto-scan VM Service ports and connect to first found Flutter app
- `list_running_apps` - List all running Flutter apps with their VM Service URIs
- `stop_app` - Stop the currently running Flutter app
- `disconnect` - Disconnect from app without stopping it
- `get_connection_status` - Get connection info with actionable suggestions
- `hot_restart` - Full app restart (resets state)

### Enhanced Tools
- `launch_app` now supports:
  - `dart_defines` - Pass compile-time variables (e.g., `["ENV=staging", "DEBUG=true"]`)
  - `flavor` - Build flavor selection
  - `target` - Custom entry point file
  - `extra_args` - Additional flutter run arguments

### Improved Error Messages
- Connection errors now include specific solutions
- `get_connection_status` shows available apps and suggestions

---

## 0.2.12

**Auto-Update Checking**

### New Features
- Auto-update checking for all installation methods
- npm: Checks registry every 24 hours, shows notification
- VSCode: Extension auto-updates via marketplace
- IntelliJ: Plugin auto-updates via JetBrains marketplace
- Homebrew: `brew upgrade flutter-skill`

---

## 0.2.11

**Homebrew Distribution**

### New Features
- Homebrew formula with pre-compiled native binary
- `brew tap ai-dashboad/flutter-skill && brew install flutter-skill`
- Auto-upgrades via `brew upgrade`

---

## 0.2.10

**IntelliJ Native Binary Support**

### New Features
- Native binary auto-download for IntelliJ/Android Studio plugin
- Background download with progress indicator
- Cached to `~/.flutter-skill/bin/`

---

## 0.2.9

**npm Native Binary Auto-Download**

### New Features
- npm postinstall script auto-downloads native binary
- Platform detection: macOS (arm64/x64), Linux (x64), Windows (x64)
- Fallback to Dart runtime if download fails

---

## 0.2.8

**Native Binary Compilation**

### Performance
- Native binary compilation for ~100x faster MCP startup
- Startup time: ~0.01s (native) vs ~1s (Dart JIT)
- GitHub Actions builds for all platforms

---

## 0.2.7

**VSCode Native Binary Support**

### New Features
- VSCode extension auto-downloads native binary
- Background download on extension activation
- Automatic fallback to Dart runtime

---

## 0.2.6

**Claude Code Config Fix**

### Bug Fixes
- Fixed Claude Code MCP config detection
- Correct path: `~/.claude/settings.json` (was incorrectly using `~/.claude.json`)
- Config now properly merges into existing settings

---

## 0.2.0

**Major Feature Release - 25+ MCP Tools**

### New Features
- **UI Inspection**: `get_widget_tree`, `get_widget_properties`, `get_text_content`, `find_by_type`
- **Interactions**: `double_tap`, `long_press`, `swipe`, `drag`
- **State Validation**: `get_text_value`, `get_checkbox_state`, `get_slider_value`, `wait_for_element`, `wait_for_gone`
- **Screenshots**: `screenshot` (full app), `screenshot_element` (specific element)
- **Navigation**: `get_current_route`, `go_back`, `get_navigation_stack`
- **Debug & Logs**: `get_logs`, `get_errors`, `get_performance`, `clear_logs`
- **Development**: `hot_reload`, `pub_search`

### Bug Fixes
- Fixed global swipe using `platformDispatcher.views` for screen center calculation
- Fixed `screenshot_element` to capture any widget by finding nearest `RenderRepaintBoundary` ancestor

### Documentation
- Complete rewrite of README.md with all tool categories
- Updated SKILL.md with full tool reference and parameters
- Updated USAGE_GUIDE.md with CLI and MCP examples

## 0.1.6

- Docs: Updated README to reflect unified `flutter_skill` global commands.

## 0.1.5

- Fix: Added missing implementation for `scroll` extension found during comprehensive verification.
- Verified: All CLI features (inspect, tap, enterText, scroll) verified against real macOS app.

## 0.1.4

- Housekeeping: Removed `demo_counter` test app from package distribution.

## 0.1.3

- Fix: Critical fix for `launch` command to correctly capture VM Service URI with auth tokens.
- Fix: Critical fix for `inspect` command to correctly traverse widget tree (was stubbed in 0.1.2).
- Feature: `launch` command now forwards arguments to `flutter run` (e.g. `-d macos`).

## 0.1.2

- Docs: Updated README architecture diagram to reflect `flutter_skill` executable.
- No functional changes.

## 0.1.1

- Featured: Simplified CLI with `flutter_skill` global executable.
- Refactor: Moved CLI logic to `lib/src/cli` for better reusability.
- Usage: `flutter_skill launch`, `flutter_skill inspect`, etc.

## 0.1.0

- Initial release of Flutter Skill.
- Includes `launch`, `inspect`, `act` CLI tools.
- Includes `flutter_skill` app-side binding.
- Includes MCP server implementation.
