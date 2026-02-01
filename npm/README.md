# Flutter Skill

> **Give your AI Agent eyes and hands inside your Flutter app.**

![Version](https://img.shields.io/pub/v/flutter_skill.svg)
![npm](https://img.shields.io/npm/v/flutter-skill-mcp.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Flutter-02569B)

**Flutter Skill** is a bridge that connects AI Agents (like Claude Code, Cursor, Windsurf) directly to running Flutter applications via the MCP (Model Context Protocol). It provides 30+ tools for UI automation, inspection, and testing.

## Quick Start

### 1. Install (choose one)

```bash
# npm (recommended - includes native binary for instant startup)
npm install -g flutter-skill-mcp

# Homebrew (macOS/Linux)
brew tap ai-dashboad/flutter-skill
brew install flutter-skill

# Dart
dart pub global activate flutter_skill

# IDE Extensions
# - VSCode: Search "Flutter Skill" in Extensions
# - IntelliJ/Android Studio: Search "Flutter Skill" in Plugins
```

### 2. Configure AI Agent

Add to your AI agent's MCP config:

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

### 3. Use

```javascript
// Option 1: Launch app with environment variables
flutter-skill.launch_app({
  project_path: "/path/to/flutter/project",
  dart_defines: ["ENV=staging", "DEBUG=true"],
  flavor: "staging"
})

// Option 2: Connect to already running app (auto-detect)
flutter-skill.scan_and_connect()

// Now use any tool
flutter-skill.screenshot()
flutter-skill.tap({ text: "Login" })
flutter-skill.inspect()
```

---

## Features

### App Lifecycle Management
| Tool | Description |
|------|-------------|
| `launch_app` | Launch Flutter app with dart_defines, flavor, target, extra_args |
| `scan_and_connect` | Auto-scan ports and connect to first running Flutter app |
| `list_running_apps` | List all running Flutter apps (VM Services) |
| `connect_app` | Connect to specific VM Service URI |
| `stop_app` | Stop the currently running app |
| `disconnect` | Disconnect without stopping the app |
| `get_connection_status` | Get connection info and suggestions |
| `hot_reload` | Fast reload (keeps state) |
| `hot_restart` | Full restart (resets state) |

### UI Inspection
| Tool | Description |
|------|-------------|
| `inspect` | Get interactive elements (buttons, text fields, etc.) |
| `get_widget_tree` | Get widget tree structure with depth control |
| `get_widget_properties` | Get properties of a widget (size, position, visibility) |
| `get_text_content` | Extract all visible text from the screen |
| `find_by_type` | Find widgets by type (e.g., ElevatedButton) |

### Interactions
| Tool | Description |
|------|-------------|
| `tap` | Tap a widget by Key or Text |
| `double_tap` | Double tap a widget |
| `long_press` | Long press with configurable duration |
| `swipe` | Swipe gesture (up/down/left/right) |
| `drag` | Drag from one element to another |
| `scroll_to` | Scroll to make an element visible |
| `enter_text` | Enter text into a text field |

### State & Validation
| Tool | Description |
|------|-------------|
| `get_text_value` | Get current value of a text field |
| `get_checkbox_state` | Get checked state of a checkbox/switch |
| `get_slider_value` | Get current value of a slider |
| `wait_for_element` | Wait for an element to appear (with timeout) |
| `wait_for_gone` | Wait for an element to disappear |

### Screenshots
| Tool | Description |
|------|-------------|
| `screenshot` | Take full app screenshot (returns base64) |
| `screenshot_element` | Take screenshot of specific element |

### Navigation
| Tool | Description |
|------|-------------|
| `get_current_route` | Get the current route name |
| `go_back` | Navigate back |
| `get_navigation_stack` | Get the navigation stack |

### Debug & Logs
| Tool | Description |
|------|-------------|
| `get_logs` | Get application logs |
| `get_errors` | Get application errors |
| `clear_logs` | Clear logs and errors |
| `get_performance` | Get performance metrics |

### Utilities
| Tool | Description |
|------|-------------|
| `pub_search` | Search Flutter packages on pub.dev |

---

## Installation Methods

| Method | Command | Auto-Update | Native Binary |
|--------|---------|-------------|---------------|
| npm | `npm install -g flutter-skill-mcp` | Manual | Auto-download |
| Homebrew | `brew install ai-dashboad/flutter-skill/flutter-skill` | `brew upgrade` | Pre-compiled |
| VSCode | Extensions → "Flutter Skill" | Auto | Auto-download |
| IntelliJ | Plugins → "Flutter Skill" | Auto | Auto-download |
| pub.dev | `dart pub global activate flutter_skill` | Manual | Dart runtime |

### Native Binary Performance
| Version | Startup Time |
|---------|--------------|
| Dart JIT | ~1 second |
| Native Binary | ~0.01 second |

Native binaries are automatically downloaded on first use for supported platforms:
- macOS (Apple Silicon & Intel)
- Linux (x64)
- Windows (x64)

---

## Flutter App Setup

For the MCP tools to work, your Flutter app needs the `flutter_skill` package:

### Automatic Setup (Recommended)
```bash
flutter-skill launch /path/to/project
# Automatically adds dependency and initializes
```

### Manual Setup
1. Add dependency:
```yaml
dependencies:
  flutter_skill: ^0.2.13
```

2. Initialize in main.dart:
```dart
import 'package:flutter_skill/flutter_skill.dart';

void main() {
  FlutterSkillBinding.ensureInitialized();
  runApp(MyApp());
}
```

---

## Example Workflows

### E2E Testing with Environment Variables
```javascript
// Launch staging environment
flutter-skill.launch_app({
  project_path: "./",
  dart_defines: ["ENV=staging", "API_URL=https://staging.api.com"],
  flavor: "staging",
  target: "lib/main_staging.dart"
})

// Wait for app to load
flutter-skill.wait_for_element({ text: "Welcome" })

// Take screenshot
flutter-skill.screenshot()

// Perform login
flutter-skill.tap({ text: "Login" })
flutter-skill.enter_text({ key: "email_field", text: "test@example.com" })
flutter-skill.enter_text({ key: "password_field", text: "password123" })
flutter-skill.tap({ text: "Submit" })

// Verify success
flutter-skill.wait_for_element({ text: "Dashboard" })
```

### Connect to Running App
```javascript
// List all running Flutter apps
flutter-skill.list_running_apps()
// Returns: { apps: ["ws://127.0.0.1:50123/ws", ...], count: 2 }

// Auto-connect to first one
flutter-skill.scan_and_connect()

// Or connect to specific one
flutter-skill.connect_app({ uri: "ws://127.0.0.1:50123/ws" })
```

### Debug a UI Issue
```javascript
// Get widget tree
flutter-skill.get_widget_tree({ max_depth: 5 })

// Find specific widgets
flutter-skill.find_by_type({ type: "ElevatedButton" })

// Inspect interactive elements
flutter-skill.inspect()

// Check if element is visible
flutter-skill.wait_for_element({ key: "submit_button", timeout: 3000 })
```

---

## IDE Extensions

### VSCode Extension
- Auto-detects Flutter projects
- Prompts to add `flutter_skill` dependency
- Auto-downloads native binary
- Status bar shows connection state
- Commands: Launch, Inspect, Screenshot

### IntelliJ/Android Studio Plugin
- Same features as VSCode
- Integrates with IDE notifications
- Tool window for status

---

## Troubleshooting

### "Not connected to Flutter app"
```javascript
// Check status and get suggestions
flutter-skill.get_connection_status()

// This returns:
// - Current connection state
// - List of available apps
// - Actionable suggestions
```

### "Unknown method ext.flutter.flutter_skill.xxx"
Your Flutter app doesn't have the `flutter_skill` package. Add it:
```bash
flutter pub add flutter_skill
```
Then restart the app (hot reload is not enough).

### MCP server slow to start
The native binary should auto-download. If not:
```bash
# For npm
npm update -g flutter-skill-mcp

# For Homebrew
brew upgrade flutter-skill
```

---

## Links

- [GitHub](https://github.com/ai-dashboad/flutter-skill)
- [pub.dev](https://pub.dev/packages/flutter_skill)
- [npm](https://www.npmjs.com/package/flutter-skill-mcp)
- [VSCode Marketplace](https://marketplace.visualstudio.com/items?itemName=ai-dashboad.flutter-skill)
- [JetBrains Marketplace](https://plugins.jetbrains.com/plugin/PLUGIN_ID)

## License

MIT
