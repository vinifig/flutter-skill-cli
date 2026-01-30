# Flutter Skill - AI App Automation

> **Give your AI Agent eyes and hands inside your Flutter app.**

Flutter Skill creates a bi-directional control channel between AI coding assistants (Claude Code, Cursor, Windsurf) and running Flutter applications through the Dart VM Service Protocol.

## Features

### UI Inspection (25+ Tools)
| Tool | Description |
|------|-------------|
| `inspect` | Get interactive elements (buttons, text fields, etc.) |
| `get_widget_tree` | Get the full widget tree structure with depth control |
| `get_widget_properties` | Get detailed properties of a widget (size, position, visibility) |
| `get_text_content` | Extract all visible text from the screen |
| `find_by_type` | Find all widgets of a specific type (e.g., ElevatedButton) |

### Interactions
| Tool | Description |
|------|-------------|
| `tap` | Tap a widget by Key or Text |
| `double_tap` | Double tap a widget |
| `long_press` | Long press a widget |
| `swipe` | Swipe gesture (up/down/left/right) globally or on element |
| `drag` | Drag from one element to another |
| `scroll_to` | Scroll to make an element visible |
| `enter_text` | Enter text into a text field |

### State & Validation
| Tool | Description |
|------|-------------|
| `get_text_value` | Get current value of a text field |
| `get_checkbox_state` | Get checked state of a checkbox |
| `get_slider_value` | Get current value of a slider |
| `wait_for_element` | Wait for an element to appear (with timeout) |
| `wait_for_gone` | Wait for an element to disappear (with timeout) |

### Screenshot & Navigation
| Tool | Description |
|------|-------------|
| `screenshot` | Capture full app screenshot (returns base64 PNG) |
| `screenshot_element` | Capture screenshot of a specific element |
| `get_current_route` | Get current route name |
| `get_navigation_stack` | Get navigation history |
| `go_back` | Navigate back to previous screen |

### Development Tools
| Tool | Description |
|------|-------------|
| `hot_reload` | Trigger hot reload |
| `get_logs` | Fetch application logs |
| `get_errors` | Get error messages |
| `get_performance` | Get performance metrics |

## VSCode Commands

| Command | Description |
|---------|-------------|
| `Flutter Skill: Launch App` | Launch Flutter app with auto-setup |
| `Flutter Skill: Inspect UI` | Show interactive elements |
| `Flutter Skill: Take Screenshot` | Capture screenshot |
| `Flutter Skill: Start MCP Server` | Start MCP server for AI agents |

## Zero Configuration Setup

Simply run "Launch App" and Flutter Skill automatically:
1. Adds the `flutter_skill` dependency if missing
2. Patches `main.dart` with initialization code
3. Launches the app and captures the VM Service URI
4. Saves connection info for subsequent commands

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `flutter-skill.dartPath` | `dart` | Path to Dart executable |
| `flutter-skill.flutterPath` | `flutter` | Path to Flutter executable |
| `flutter-skill.autoConnect` | `true` | Auto-connect when app starts |

## MCP Server Integration

Works seamlessly with MCP-compatible AI agents. Add to your MCP configuration:

```json
{
  "flutter-skill": {
    "command": "flutter-skill",
    "args": ["server"]
  }
}
```

Alternative configurations:

```json
// If installed via Homebrew
{
  "flutter-skill": {
    "command": "flutter-skill-mcp"
  }
}

// Via npx
{
  "flutter-skill": {
    "command": "npx",
    "args": ["flutter-skill-mcp"]
  }
}
```

## Installation Options

- **pub.dev:** `dart pub global activate flutter_skill`
- **Homebrew:** `brew install ai-dashboad/flutter-skill/flutter-skill`
- **npm:** `npx flutter-skill-mcp`

## Requirements

- Flutter SDK
- Dart SDK
- A Flutter project

## Links

- [GitHub Repository](https://github.com/ai-dashboad/flutter-skill)
- [pub.dev Package](https://pub.dev/packages/flutter_skill)
- [npm Package](https://www.npmjs.com/package/flutter-skill-mcp)
- [JetBrains Plugin](https://plugins.jetbrains.com/plugin/29991-flutter-skill)

## License

MIT
