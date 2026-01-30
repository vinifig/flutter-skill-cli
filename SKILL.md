---
description: Controls a running Flutter application using the `marionette_flutter` instrumented package. Allows inspecting widgets, tapping, entering text, and taking screenshots.
---

# Flutter Skill

This skill allows you to interact with a running Flutter application to verify features, debug UI, or run smoke tests.
It works by connecting to the Dart VM Service using a set of Dart scripts.

## Usage

### 1. Launch & Auto-Setup
The easiest way to start is to use the launcher script. It will **automatically** add dependencies to your app, patch `main.dart`, and connect to it.

```bash
dart run scripts/launch.dart <project_path>
```
*   `project_path`: Path to your Flutter project (default: `.`).
*   This script will keep running. **Open a new terminal** for the next steps.

### 2. Interaction
Once the app is launched, you can inspect and control it without providing the URI (it's cached).

**Inspect**:
```bash
dart run scripts/inspect.dart
```

**Tap**:
```bash
dart run scripts/act.dart tap "login_button"
```

**Enter Text**:
```bash
dart run scripts/act.dart enter_text "email_field" "hello@example.com"
```

**Common Argument**:
- `<vm-uri>`: Optional if you used `launch.dart`. Otherwise required.

### 1. Inspect UI
View the interactive widget tree (Buttons, TextFields, etc.).

```bash
dart run scripts/inspect.dart <vm-uri>
```
*Output*: A tree of widgets with their `key`, `text`, and `type`. Use this to find keys for interaction.

### 2. Perform Actions
Interact with widgets using `tap`, `enter_text`, or `scroll_to`.

**Tap**:
```bash
dart run scripts/act.dart <vm-uri> tap <key_or_text>
```

**Enter Text**:
```bash
dart run scripts/act.dart <vm-uri> enter_text <key> "Hello World"
```

**Scroll**:
```bash
dart run scripts/act.dart <vm-uri> scroll_to <key_or_text>
```

### 3. Developer Assistant (New!)
Mimics the official "Developer" capabilities.

**Find Package**:
Finds packages on pub.dev.
```bash
dart run scripts/pub_search.dart "chart"
```

**Inspect Layout**:
Deep inspection of the Widget tree (Rows, Columns) for debugging layout.
```bash
dart run scripts/inspect_layout.dart <vm-uri>
```

### 4. Verification & Debugging

**Wait for Element**:
Use this to handle loading states or animations.
```bash
dart run scripts/wait_for.dart <vm-uri> <key_or_text> [timeout_seconds]
```

**Get Logs**:
View application logs (from `print` or exceptions).
```bash
dart run scripts/log.dart <vm-uri>
```

**Hot Reload**:
Reload code changes instantly.
```bash
dart run scripts/reload.dart <vm-uri>
```

**Assertions**:
Verify UI state in your flows.
```bash
dart run scripts/act.dart <vm-uri> assert_visible <key_or_text>
dart run scripts/act.dart <vm-uri> assert_gone <key_or_text>
```

### 4. Take Screenshot
Capture the current screen state.

```bash
dart run scripts/screenshot.dart <vm-uri> [output_path]
```

## Examples

**Verify Counter Increment**:
```bash
# 1. Get URI
# ws://127.0.0.1:62058/ws

# 2. Inspect to find button
dart run scripts/inspect.dart ws://127.0.0.1:62058/ws

# 3. Tap button
dart run scripts/act.dart ws://127.0.0.1:62058/ws tap "increment_button"

# 4. Inspect to verify value changed
dart run scripts/inspect.dart ws://127.0.0.1:62058/ws
```
