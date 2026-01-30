# Continue.dev Integration

This guide explains how to use Flutter Skill with [Continue.dev](https://continue.dev), the open-source AI code assistant.

## Quick Setup

1. **Install Flutter Skill**

   ```bash
   # Via npm
   npm install -g @anthropic/flutter-skill

   # Via Homebrew
   brew install ai-dashboad/flutter-skill/flutter-skill

   # Via pub.dev
   dart pub global activate flutter_skill
   ```

2. **Configure Continue.dev**

   Add to your `~/.continue/config.json`:

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

3. **Start Your Flutter App**

   ```bash
   flutter-skill launch /path/to/your/flutter-app
   ```

4. **Use with Continue**

   Now you can ask Continue to interact with your Flutter app:
   - "Inspect the current UI"
   - "Tap the login button"
   - "Enter 'test@example.com' in the email field"
   - "Take a screenshot"

## Available MCP Tools

| Tool | Description |
|------|-------------|
| `inspect` | Get interactive elements in the app |
| `tap` | Tap on a widget by key or text |
| `enter_text` | Enter text in a text field |
| `scroll` | Scroll to a widget |
| `screenshot` | Capture the current screen |
| `widget_tree` | Get the full widget tree |
| `get_text` | Get text content from widgets |
| `diagnose` | Analyze logs for issues |

## Example Workflows

### Testing a Login Flow

```
You: "Test the login flow with user@example.com and password123"

Continue will:
1. Inspect the UI to find input fields
2. Enter the email in the email field
3. Enter the password in the password field
4. Tap the login button
5. Take a screenshot to verify the result
```

### Debugging UI Issues

```
You: "Check if there are any layout overflow issues"

Continue will:
1. Use the diagnose tool to analyze logs
2. Report any detected issues
3. Suggest fixes based on the error patterns
```

## Tips

1. **Use ValueKeys**: Add `ValueKey` to important widgets for reliable targeting:
   ```dart
   TextField(
     key: const ValueKey('email_field'),
     // ...
   )
   ```

2. **Enable Debug Mode**: Flutter Skill only works in debug mode:
   ```dart
   void main() {
     if (kDebugMode) {
       FlutterSkillBinding.ensureInitialized();
     }
     runApp(const MyApp());
   }
   ```

3. **Check Connection**: Use the status bar indicator in VSCode/IntelliJ to verify connection.

## Troubleshooting

### "No Flutter app connected"

- Ensure your Flutter app is running with `flutter-skill launch`
- Check that `FlutterSkillBinding.ensureInitialized()` is called in main.dart
- Verify the VM Service URI in `.flutter_skill_uri`

### "Tool not found"

- Restart the MCP server: `flutter-skill server`
- Check Continue.dev config is correctly formatted

## Resources

- [Flutter Skill GitHub](https://github.com/ai-dashboad/flutter-skill)
- [Continue.dev Documentation](https://docs.continue.dev)
- [MCP Protocol Spec](https://modelcontextprotocol.io)
