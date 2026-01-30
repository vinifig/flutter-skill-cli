---
description: Controls a running Flutter application via Dart VM Service. Allows inspecting widgets, performing gestures, validating state, taking screenshots, and debugging.
---

# Flutter Skill

This skill allows AI Agents to interact with a running Flutter application for feature verification, UI debugging, and automated testing. It connects to the Dart VM Service and provides 25+ tools for comprehensive app control.

## Quick Start

### 1. Launch & Auto-Setup

The easiest way to start - automatically adds dependencies and patches your app:

```bash
flutter_skill launch <project_path>
```

Or run directly:
```bash
dart run bin/flutter_skill.dart launch <project_path>
```

This will:
- Add `flutter_skill` dependency if missing
- Inject `FlutterSkillBinding.ensureInitialized()` into `main.dart`
- Run `flutter run` and capture the VM Service URI
- Save URI to `.flutter_skill_uri` for subsequent commands

### 2. Interact

Once launched, use CLI commands or MCP tools:

**CLI Mode:**
```bash
flutter_skill inspect
flutter_skill act tap "login_button"
flutter_skill act enter_text "email_field" "hello@example.com"
flutter_skill screenshot ./screenshot.png
```

**MCP Mode:**
Configure your editor to use the MCP server, then tools are available to the Agent.

---

## MCP Server Configuration

Add to your MCP config (Cursor, Windsurf, Claude Desktop):

```json
{
  "flutter-skill": {
    "command": "dart",
    "args": ["run", "/path/to/flutter-skill/bin/server.dart"]
  }
}
```

---

## Complete Tool Reference

### Connection

| Tool | Description | Parameters |
|------|-------------|------------|
| `connect_app` | Connect to running app | `uri` (WebSocket URI) |
| `launch_app` | Launch app with auto-setup | `project_path`, `device_id` (optional) |

### UI Inspection

| Tool | Description | Parameters |
|------|-------------|------------|
| `inspect` | Get interactive elements | - |
| `get_widget_tree` | Full widget tree | `depth` (optional, default: 10) |
| `get_widget_properties` | Widget details | `key` |
| `get_text_content` | All visible text | - |
| `find_by_type` | Find widgets by type | `type` (e.g., "ElevatedButton") |

### Interactions

| Tool | Description | Parameters |
|------|-------------|------------|
| `tap` | Tap element | `key` or `text` |
| `double_tap` | Double tap | `key` or `text` |
| `long_press` | Long press | `key` or `text` |
| `swipe` | Swipe gesture | `direction` (up/down/left/right), `distance`, `key` (optional) |
| `drag` | Drag between elements | `from_key`, `to_key` |
| `scroll_to` | Scroll element into view | `key` or `text` |
| `enter_text` | Input text | `key`, `text` |

### State & Validation

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_text_value` | Get text field value | `key` |
| `get_checkbox_state` | Get checkbox state | `key` |
| `get_slider_value` | Get slider value | `key` |
| `wait_for_element` | Wait for element | `key` or `text`, `timeout` (ms) |
| `wait_for_gone` | Wait for element gone | `key` or `text`, `timeout` (ms) |

### Screenshot

| Tool | Description | Parameters |
|------|-------------|------------|
| `screenshot` | Full app screenshot | - (returns base64 PNG) |
| `screenshot_element` | Element screenshot | `key` (returns base64 PNG) |

### Navigation

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_current_route` | Current route name | - |
| `get_navigation_stack` | Navigation history | - |
| `go_back` | Navigate back | - |

### Debug & Logs

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_logs` | Application logs | - |
| `get_errors` | Error messages | - |
| `get_performance` | Performance metrics | - |
| `clear_logs` | Clear log buffer | - |

### Development

| Tool | Description | Parameters |
|------|-------------|------------|
| `hot_reload` | Trigger hot reload | - |
| `pub_search` | Search pub.dev | `query` |

---

## Usage Examples

### Example 1: Verify Counter App

```bash
# 1. Launch the app
flutter_skill launch ./my_counter_app

# 2. Inspect to find elements
flutter_skill inspect

# 3. Tap increment button
flutter_skill act tap "increment_button"

# 4. Verify counter changed
flutter_skill inspect
```

### Example 2: Test Login Flow

```bash
# Enter credentials
flutter_skill act enter_text "email_field" "user@example.com"
flutter_skill act enter_text "password_field" "secret123"

# Tap login button
flutter_skill act tap "login_button"

# Wait for home screen
flutter_skill act wait_for "home_screen" 5000

# Verify navigation
flutter_skill act get_current_route
```

### Example 3: Test Scrollable List

```bash
# Swipe up to scroll
flutter_skill act swipe up 300 "list_view"

# Or scroll to specific item
flutter_skill act scroll_to "item_50"

# Take screenshot
flutter_skill screenshot ./list_screenshot.png
```

### Example 4: Debug Issues

```bash
# Check for errors
flutter_skill logs errors

# Get performance info
flutter_skill logs performance

# View all logs
flutter_skill logs
```

---

## Widget Keys Best Practice

For reliable element identification, add `ValueKey` to widgets:

```dart
ElevatedButton(
  key: const ValueKey('submit_button'),
  onPressed: _submit,
  child: const Text('Submit'),
)

TextField(
  key: const ValueKey('email_input'),
  controller: _emailController,
)
```

Elements can be found by:
1. **Key** (most reliable): `"submit_button"`
2. **Text content**: `"Submit"`
3. **Widget type**: `"ElevatedButton"`

---

## Manual Setup (If Needed)

Usually not required - `launch` handles this automatically.

**pubspec.yaml:**
```yaml
dependencies:
  flutter_skill:
    path: /path/to/flutter-skill
```

**main.dart:**
```dart
import 'package:flutter_skill/flutter_skill.dart';
import 'package:flutter/foundation.dart';

void main() {
  if (kDebugMode) {
    FlutterSkillBinding.ensureInitialized();
  }
  runApp(const MyApp());
}
```
