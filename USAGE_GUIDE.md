# How to Use Flutter Skill

This skill supports two modes: **CLI Mode** (for Claude Code) and **MCP Server Mode** (for Cursor, Windsurf, Claude Desktop).

## 1. CLI Mode (Claude Code / Terminal)

### Launch & Auto-Setup

```bash
# Launch app with automatic setup
flutter_skill launch /path/to/your/flutter_project

# Or run directly without global install
dart run bin/flutter_skill.dart launch /path/to/your/flutter_project

# Specify device
flutter_skill launch . -d macos
flutter_skill launch . -d chrome
flutter_skill launch . -d <device_id>
```

### Inspect & Interact

```bash
# Inspect UI elements
flutter_skill inspect

# Tap a button
flutter_skill act tap "login_button"

# Enter text
flutter_skill act enter_text "email_field" "hello@example.com"

# Scroll to element
flutter_skill act scroll_to "bottom_item"

# Take screenshot
flutter_skill screenshot ./screenshot.png
```

---

## 2. MCP Server Mode (Cursor / IDEs)

### Configuration

Add to your MCP settings:

```json
{
  "flutter-skill": {
    "command": "dart",
    "args": ["run", "/absolute/path/to/flutter-skill/bin/server.dart"]
  }
}
```

### Usage

Just ask the Agent:
- "Launch my Flutter app and test the login screen"
- "Tap the submit button and verify the result"
- "Take a screenshot of the current screen"

The Agent will automatically:
1. Call `launch_app` or `connect_app`
2. Auto-patch `pubspec.yaml` and `main.dart` if needed
3. Use tools like `inspect`, `tap`, `screenshot`

---

## Available Tools (25+)

### Connection
- `connect_app` - Connect to running app via URI
- `launch_app` - Launch app with auto-setup

### UI Inspection
- `inspect` - Get interactive elements
- `get_widget_tree` - Full widget tree structure
- `get_widget_properties` - Widget details (size, position)
- `get_text_content` - All visible text
- `find_by_type` - Find widgets by type

### Interactions
- `tap` - Single tap
- `double_tap` - Double tap
- `long_press` - Long press
- `swipe` - Swipe gesture (up/down/left/right)
- `drag` - Drag from one element to another
- `scroll_to` - Scroll element into view
- `enter_text` - Input text

### State & Validation
- `get_text_value` - Get text field value
- `get_checkbox_state` - Get checkbox state
- `get_slider_value` - Get slider value
- `wait_for_element` - Wait for element to appear
- `wait_for_gone` - Wait for element to disappear

### Screenshot
- `screenshot` - Full app screenshot (base64 PNG)
- `screenshot_element` - Element screenshot (base64 PNG)

### Navigation
- `get_current_route` - Current route name
- `get_navigation_stack` - Navigation history
- `go_back` - Navigate back

### Debug & Logs
- `get_logs` - Application logs
- `get_errors` - Error messages
- `get_performance` - Performance metrics
- `clear_logs` - Clear log buffer

### Development
- `hot_reload` - Trigger hot reload
- `pub_search` - Search pub.dev packages

---

## Target App Setup (Manual)

*Usually NOT needed - the launch command handles this automatically.*

**pubspec.yaml**:
```yaml
dependencies:
  flutter_skill:
    path: /path/to/flutter-skill
```

**main.dart**:
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

---

## Best Practices

### Use Widget Keys

For reliable element identification:

```dart
ElevatedButton(
  key: const ValueKey('submit_button'),
  onPressed: _submit,
  child: const Text('Submit'),
)
```

### Element Finding Priority

1. **Key** (most reliable): `tap "submit_button"`
2. **Text content**: `tap "Submit"`
3. **Widget type**: `find_by_type "ElevatedButton"`
