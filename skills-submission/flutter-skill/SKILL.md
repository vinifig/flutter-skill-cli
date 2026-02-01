---
name: flutter-skill
description: Control and automate Flutter applications - inspect UI, perform gestures, validate state, take screenshots, and debug. Connects AI agents to running Flutter apps via Dart VM Service Protocol.
---

# Flutter Skill

Give your AI Agent eyes and hands inside your Flutter app. This skill enables comprehensive control of Flutter applications for testing, debugging, and automation.

## Installation

### Option 1: npx (Recommended)
```json
{
  "flutter-skill": {
    "command": "npx",
    "args": ["flutter-skill-mcp"]
  }
}
```

### Option 2: Global Install
```bash
dart pub global activate flutter_skill
```

Then configure:
```json
{
  "flutter-skill": {
    "command": "flutter_skill",
    "args": ["server"]
  }
}
```

## Available Tools

### Connection
- `connect_app` - Connect to a running Flutter app via WebSocket URI
- `launch_app` - Launch a Flutter app with auto-setup (adds dependencies, patches main.dart)

### UI Inspection
- `inspect` - Get interactive elements (buttons, text fields, etc.)
- `get_widget_tree` - Full widget tree structure with configurable depth
- `get_widget_properties` - Widget details (size, position, visibility)
- `get_text_content` - Extract all visible text from screen
- `find_by_type` - Find all widgets of a specific type

### Interactions
- `tap` - Tap element by key or text
- `double_tap` - Double tap gesture
- `long_press` - Long press gesture
- `swipe` - Swipe up/down/left/right
- `drag` - Drag from one element to another
- `scroll_to` - Scroll element into view
- `enter_text` - Input text into text field

### State Validation
- `get_text_value` - Get text field value
- `get_checkbox_state` - Get checkbox checked state
- `get_slider_value` - Get slider current value
- `wait_for_element` - Wait for element to appear (with timeout)
- `wait_for_gone` - Wait for element to disappear

### Screenshots
- `screenshot` - Capture full app screenshot (base64 PNG)
- `screenshot_element` - Capture specific element screenshot

### Navigation
- `get_current_route` - Get current route name
- `go_back` - Navigate back
- `get_navigation_stack` - Get navigation history

### Debug & Logs
- `get_logs` - Application logs
- `get_errors` - Error messages
- `get_performance` - Performance metrics
- `clear_logs` - Clear log buffer
- `hot_reload` - Trigger hot reload

## Usage Examples

### Test a Counter App
```
1. Launch the app: launch_app with project_path="/path/to/app"
2. Inspect UI: inspect
3. Tap increment: tap with key="increment_button"
4. Verify: get_text_content to see updated counter
```

### Test a Login Flow
```
1. Enter email: enter_text with key="email_field", text="user@example.com"
2. Enter password: enter_text with key="password_field", text="password123"
3. Tap login: tap with key="login_button"
4. Wait for home: wait_for_element with key="home_screen", timeout=5000
```

### Debug an Issue
```
1. Connect: connect_app with uri="ws://127.0.0.1:xxxxx/ws"
2. Check errors: get_errors
3. View logs: get_logs
4. Take screenshot: screenshot
```

## Best Practices

### Use Widget Keys
For reliable element identification, target apps should use `ValueKey`:
```dart
ElevatedButton(
  key: const ValueKey('submit_button'),
  onPressed: _submit,
  child: const Text('Submit'),
)
```

### Element Finding Priority
1. **Key** (most reliable): `tap with key="submit_button"`
2. **Text content**: `tap with text="Submit"`
3. **Widget type**: `find_by_type with type="ElevatedButton"`

## Links

- [GitHub Repository](https://github.com/ai-dashboad/flutter-skill)
- [pub.dev Package](https://pub.dev/packages/flutter_skill)
- [npm Package](https://www.npmjs.com/package/flutter-skill-mcp)
