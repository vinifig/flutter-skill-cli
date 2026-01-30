# How to Use Flutter Skill

This skill supports two modes: **CLI Mode** (for Claude Code) and **MCP Server Mode** (for Cursor, Windsurf, Claude Desktop).

## 1. CLI Mode (Claude Code / Terminal)

**Enhanced Workflow (Auto-Setup & Auto-Connect):**
1.  **Launch**:
    ```bash
    dart run scripts/launch.dart .
    ```
    *   **Magic**: If your app isn't configured, this script will **automatically** add the dependency and modify `main.dart` for you!
    *   *(Keeps running and prints app logs)*

2.  **Interact (In new terminal)**:
    ```bash
    dart run scripts/inspect.dart
    dart run scripts/act.dart tap "login_btn"
    ```

---

## 2. MCP Server Mode (Cursor / IDEs)

### Cursor Configuration
*   **Command**: `dart`
*   **Args**: `run /Users/cw/development/flutter-skill/scripts/server.dart`

**Usage**:
Just say: **"Launch the app and test the login screen."**

The Agent will:
1.  Call `launch_app(".")`.
2.  **Magic**: It will auto-patch your `pubspec.yaml` and `main.dart` if needed.
3.  Wait for the app to start and auto-connect.
4.  Proceed to `inspect` and `tap`.

---

## Target App Setup (Manual)
*You usually DO NOT need this anymore, as the tools above do it automatically.*

**pubspec.yaml**:
```yaml
dependencies:
  flutter_skill: ^1.0.0
```

**main.dart**:
```dart
if (kDebugMode) {
  FlutterSkillBinding.ensureInitialized();
}
```
