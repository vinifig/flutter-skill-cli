# Flutter Skill

> **AI-Powered End-to-End Testing for Flutter Apps**

![Version](https://img.shields.io/pub/v/flutter_skill.svg)
![npm](https://img.shields.io/npm/v/flutter-skill-mcp.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Flutter-02569B)

**Flutter Skill** is an E2E testing bridge that gives AI agents (Claude Code, Cursor, Windsurf, etc.) full control over running Flutter apps. Describe what you want to test in natural language, and the AI sees the screen, taps buttons, fills forms, scrolls, and verifies results - just like a human tester would.

```
You: "Test the login flow - enter test@example.com and password123, tap Login, verify Dashboard appears"

AI Agent:
  1. screenshot()          → sees the login screen
  2. enter_text("email")   → types the email
  3. enter_text("password") → types the password
  4. tap("Login")           → taps the button
  5. wait_for_element("Dashboard") → confirms navigation
  6. screenshot()          → captures the result
  ✅ Login flow verified!
```

## Why Flutter Skill?

| Traditional E2E Testing | Flutter Skill |
|------------------------|---------------|
| Write Dart test code manually | Describe tests in natural language |
| Learn WidgetTester API | AI handles the automation |
| Maintain brittle test scripts | AI adapts to UI changes |
| Debug test failures manually | AI sees screenshots and self-corrects |
| Setup takes hours | Setup takes 2 minutes |

**Flutter Skill is for you if:**
- You want E2E tests without writing test code
- You're using AI coding agents (Claude Code, Cursor, Windsurf)
- You want to automate QA workflows with natural language
- You need to test real app behavior on simulators/emulators

---

## Quick Start (2 minutes)

### 1. Install

```bash
# One-click install (macOS/Linux) - recommended
curl -fsSL https://raw.githubusercontent.com/ai-dashboad/flutter-skill/main/install.sh | bash

# Or: npm (all platforms)
npm install -g flutter-skill-mcp

# Or: Homebrew (macOS/Linux)
brew tap ai-dashboad/flutter-skill && brew install flutter-skill

# Or: Dart
dart pub global activate flutter_skill
```

<details>
<summary>More installation methods (Windows, Docker, IDE extensions...)</summary>

| Method | Command | Platform |
|--------|---------|----------|
| **One-click** | `curl -fsSL .../install.sh \| bash` | macOS/Linux |
| **Windows** | `iwr .../install.ps1 -useb \| iex` | Windows |
| **npm** | `npm install -g flutter-skill-mcp` | All |
| **Homebrew** | `brew install ai-dashboad/flutter-skill/flutter-skill` | macOS/Linux |
| **Scoop** | `scoop install flutter-skill` | Windows |
| **Docker** | `docker pull ghcr.io/ai-dashboad/flutter-skill` | All |
| **pub.dev** | `dart pub global activate flutter_skill` | All |
| **VSCode** | Extensions -> "Flutter Skill" | All |
| **IntelliJ** | Plugins -> "Flutter Skill" | All |

</details>

### 2. Configure Your AI Agent

Add to your agent's MCP config:

**Claude Code** (`~/.claude/settings.json`):
```json
{
  "mcpServers": {
    "flutter-skill": {
      "command": "flutter-skill",
      "args": ["server"]
    }
  }
}
```

<details>
<summary>Cursor, Windsurf, and other agents</summary>

**Cursor** (`~/.cursor/mcp.json`):
```json
{
  "mcpServers": {
    "flutter-skill": {
      "command": "flutter-skill",
      "args": ["server"]
    }
  }
}
```

Any MCP-compatible agent uses the same config format.

</details>

### 3. Add to Your Flutter App

```yaml
# pubspec.yaml
dependencies:
  flutter_skill: ^0.7.2
```

```dart
// main.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_skill/flutter_skill.dart';

void main() {
  if (kDebugMode) {
    FlutterSkillBinding.ensureInitialized();
  }
  runApp(MyApp());
}
```

> **Tip:** `launch_app` can auto-add this for you. The `kDebugMode` guard ensures it's stripped from release builds.

### 4. Start Testing

Just tell your AI agent what to test:

```
"Launch my app on iPhone simulator, tap the Sign Up button, fill in the form, and verify the success screen"
```

Or use tools directly:
```javascript
flutter-skill.launch_app({ project_path: "." })
flutter-skill.inspect()                          // See all interactive elements
flutter-skill.tap({ text: "Sign Up" })           // Tap by text
flutter-skill.enter_text({ key: "email", text: "user@test.com" })
flutter-skill.screenshot()                       // Visual verification
```

---

## What Can It Do?

### 40+ MCP Tools for Complete App Control

**Launch & Connect**
| Tool | What it does |
|------|-------------|
| `launch_app` | Launch app with dart-defines, flavors, custom targets |
| `scan_and_connect` | Auto-find and connect to any running Flutter app |
| `hot_reload` / `hot_restart` | Reload code without restarting |

**See the Screen**
| Tool | What it does |
|------|-------------|
| `screenshot` | Full app screenshot (configurable quality) |
| `screenshot_region` | Screenshot a specific area |
| `screenshot_element` | Screenshot a single widget |
| `native_screenshot` | OS-level screenshot (native dialogs, permission popups) |
| `inspect` | List all interactive elements with coordinates |
| `get_widget_tree` | Full widget tree structure |
| `find_by_type` | Find widgets by type (e.g., `ElevatedButton`) |
| `get_text_content` | Extract all visible text |

**Interact Like a User**
| Tool | What it does |
|------|-------------|
| `tap` | Tap by Key, text, or coordinates |
| `double_tap` | Double tap |
| `long_press` | Long press with configurable duration |
| `enter_text` | Type into text fields (by key or focused field) |
| `swipe` | Swipe gestures (up/down/left/right) |
| `scroll_to` | Scroll until element is visible |
| `drag` | Drag from one element to another |
| `go_back` | Navigate back |
| `native_tap` | Tap native UI (permission dialogs, photo pickers) |
| `native_input_text` | Type into native text fields |
| `native_swipe` | Scroll native views |

**Verify & Assert**
| Tool | What it does |
|------|-------------|
| `assert_text` | Verify element contains expected text |
| `assert_visible` | Verify element is visible |
| `assert_not_visible` | Verify element is gone |
| `assert_element_count` | Verify number of matching elements |
| `wait_for_element` | Wait for element to appear (with timeout) |
| `wait_for_gone` | Wait for element to disappear |
| `get_checkbox_state` | Read checkbox/switch state |
| `get_slider_value` | Read slider value |
| `get_text_value` | Read text field value |

**Debug & Monitor**
| Tool | What it does |
|------|-------------|
| `get_logs` | Read application logs |
| `get_errors` | Read application errors |
| `get_performance` | Performance metrics |
| `get_memory_stats` | Memory usage stats |

**Multi-Session**
| Tool | What it does |
|------|-------------|
| `list_sessions` | See all connected apps |
| `switch_session` | Switch between apps |
| `close_session` | Disconnect from an app |

---

## Example Workflows

### Login Flow Test
```
You: "Test login with test@example.com / password123, verify it reaches the dashboard"
```
The AI agent will:
1. `launch_app` or `scan_and_connect` to your app
2. `screenshot` to see the current screen
3. `enter_text(key: "email_field", text: "test@example.com")`
4. `enter_text(key: "password_field", text: "password123")`
5. `tap(text: "Login")`
6. `wait_for_element(text: "Dashboard")`
7. `screenshot` to confirm

### Form Validation Test
```
You: "Submit the registration form empty and check that all validation errors appear"
```

### Navigation Test
```
You: "Navigate through all tabs, take a screenshot of each, and verify the back button works"
```

### Visual Regression
```
You: "Take screenshots of the home, profile, and settings pages - compare them with last time"
```

---

## Native Platform Support

Flutter Skill can interact with **native dialogs** that Flutter can't see (permission popups, photo pickers, share sheets):

| Tool | iOS Simulator | Android Emulator |
|------|--------------|-----------------|
| `native_screenshot` | `xcrun simctl screenshot` | `adb screencap` |
| `native_tap` | macOS Accessibility API | `adb input tap` |
| `native_input_text` | Pasteboard + Cmd+V | `adb input text` |
| `native_swipe` | Accessibility scroll | `adb input swipe` |

No external tools needed - works with built-in OS capabilities.

---

## Flutter 3.x Compatibility

Flutter 3.x defaults to the DTD protocol. Flutter Skill auto-adds `--vm-service-port=50000` to ensure VM Service protocol is available. No manual configuration needed.

If you see "no VM Service URI" errors:
```javascript
// Explicitly set a port
flutter-skill.launch_app({
  project_path: ".",
  extra_args: ["--vm-service-port=50000"]
})
```

---

## Tool Priority Setup (Claude Code)

For Claude Code users, ensure it always uses Flutter Skill for Flutter testing:

```bash
flutter_skill setup
```

This installs priority rules so Claude Code automatically chooses Flutter Skill over Dart MCP, giving you full UI automation (tap, screenshot, swipe) instead of read-only inspection.

---

## IDE Extensions

### VSCode Extension
- Auto-detects Flutter projects
- Status bar shows connection state
- Commands: Launch, Inspect, Screenshot

### IntelliJ / Android Studio Plugin
- Same features as VSCode
- Integrates with IDE notifications

---

## Troubleshooting

### "Not connected to Flutter app"
```javascript
flutter-skill.get_connection_status()  // Shows suggestions
flutter-skill.scan_and_connect()       // Auto-find running apps
```

### "Unknown method ext.flutter.flutter_skill.xxx"
Your app doesn't have the flutter_skill package:
```bash
flutter pub add flutter_skill
```
Then restart the app (hot reload is not enough for new packages).

### More help
- [Usage Guide](docs/USAGE_GUIDE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Flutter 3.x Fix](docs/FLUTTER_3X_FIX.md)

---

## Links

- [GitHub](https://github.com/ai-dashboad/flutter-skill)
- [pub.dev](https://pub.dev/packages/flutter_skill)
- [npm](https://www.npmjs.com/package/flutter-skill-mcp)
- [VSCode Marketplace](https://marketplace.visualstudio.com/items?itemName=ai-dashboad.flutter-skill)
- [JetBrains Marketplace](https://plugins.jetbrains.com/plugin/29991-flutter-skill)
- [Roadmap](docs/ROADMAP.md)

## Support This Project

If Flutter Skill helps you build better Flutter apps, consider supporting its development:

- [GitHub Sponsors](https://github.com/sponsors/ai-dashboad)
- [Buy Me a Coffee](https://buymeacoffee.com/ai-dashboad)

Your support helps maintain the project, add new features, and keep it free and open source.

---

## License

MIT
