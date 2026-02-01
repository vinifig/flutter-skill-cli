# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Flutter Skill is a bridge that connects AI Agents to running Flutter applications via the Dart VM Service Protocol. It enables agents to inspect UI structure, perform actions (tap, scroll, enter text), and verify visual changes.

## Common Commands

```bash
# Activate the CLI globally (from this repo)
dart pub global activate --source path .

# Run the CLI directly without global activation
dart run bin/flutter_skill.dart <command>

# Launch a Flutter app with auto-setup (adds dependency + patches main.dart)
flutter_skill launch /path/to/flutter_project

# Inspect interactive widgets in running app
flutter_skill inspect

# Perform actions
flutter_skill act tap "button_key"
flutter_skill act enter_text "field_key" "text value"

# Run integration tests (uses mock Flutter app)
dart run test/integration_test.dart
```

## Architecture

The codebase has two main parts:

**1. Target App Library** (`lib/flutter_skill.dart`)
- `FlutterSkillBinding` - Registers VM Service extensions in the Flutter app
- Extensions: `ext.flutter.flutter_skill.interactive`, `.tap`, `.enterText`, `.scroll`
- Target apps call `FlutterSkillBinding.ensureInitialized()` in main.dart

**2. CLI/Server Tools** (`lib/src/`)
- `FlutterSkillClient` (`flutter_skill_client.dart`) - Connects to VM Service, calls extensions
- `lib/src/cli/` - CLI command implementations (launch, inspect, act, server, setup)
- MCP Server mode (`server.dart`) - JSON-RPC interface for IDEs like Cursor

**Entry Points:**
- `bin/flutter_skill.dart` - Main CLI entry point, routes to subcommands
- `bin/server.dart` - Standalone MCP server entry point
- Individual `bin/*.dart` scripts - Direct script access (legacy style)

**Connection Flow:**
1. `launch` runs `flutter run`, captures VM Service URI from stdout
2. URI saved to `.flutter_skill_uri` for subsequent commands
3. `FlutterSkillClient` connects via WebSocket, finds main isolate
4. Commands invoke registered extensions on the running app

## Key Files

- `lib/flutter_skill.dart` - The binding that target apps import
- `lib/src/flutter_skill_client.dart` - VM Service client wrapper
- `lib/src/cli/setup.dart` - Auto-patches pubspec.yaml and main.dart
- `test/bin/flutter` - Mock flutter CLI for integration tests

## Release Process

### Quick Release

When the user asks to release a new version:

```bash
# Option 1: Automated (recommended)
./scripts/release.sh 0.3.2 "Brief description"

# Option 2: Manual (for fine control)
# See RELEASE_PROCESS.md for detailed steps
```

### Manual Release Steps

1. **Prepare CHANGELOG**
   - If there's a `RELEASE_NOTES_vX.Y.Z.md`, extract key points
   - Add concise entry to `CHANGELOG.md` (at the top)
   - Follow existing format: version, description, features, docs

2. **Update Version Numbers**
   - `pubspec.yaml` - version: X.Y.Z
   - `lib/src/cli/server.dart` - const String _currentVersion = 'X.Y.Z'
   - `npm/package.json` - "version": "X.Y.Z"
   - `vscode-extension/package.json` - "version": "X.Y.Z"
   - `intellij-plugin/build.gradle.kts` - version = "X.Y.Z"
   - `intellij-plugin/src/main/resources/META-INF/plugin.xml` - <version>X.Y.Z</version>
   - `README.md` - flutter_skill: ^X.Y.Z

3. **Commit and Tag**
   ```bash
   git add -A
   git commit -m "chore: Release vX.Y.Z\n\n<description>"
   git tag vX.Y.Z
   git push origin main --tags
   ```

4. **Verify**
   - Check GitHub Actions: https://github.com/ai-dashboad/flutter-skill/actions
   - Verify auto-publish to: pub.dev, npm, VSCode, JetBrains, Homebrew

### Version Numbering

Follow [Semantic Versioning](https://semver.org/):
- `MAJOR.MINOR.PATCH` (e.g., 0.3.1)
- **PATCH** (0.3.0 → 0.3.1): Bug fixes, optimizations, small improvements
- **MINOR** (0.3.0 → 0.4.0): New features, backward-compatible changes
- **MAJOR** (0.x.x → 1.0.0): Breaking changes, major refactor

### Complete Documentation

See `RELEASE_PROCESS.md` for:
- Detailed manual steps
- Troubleshooting
- Special release scenarios
- Post-release checklist

## Tool Selection Rules

### Flutter Testing - ALWAYS Use flutter-skill

**CRITICAL**: For ANY Flutter app testing, ALWAYS use flutter-skill MCP tools, NEVER use Dart MCP.

#### Decision Matrix

| User Request | Tool to Use | DO NOT USE |
|--------------|-------------|------------|
| Test Flutter app | `flutter-skill` | ❌ Dart MCP |
| Launch app | `launch_app` with `--vm-service-port=50000` | ❌ `mcp__dart__launch_app` |
| Get logs | `get_logs` | ❌ `mcp__dart__get_app_logs` |
| Hot reload | `hot_reload` | ❌ `mcp__dart__hot_reload` |
| Inspect UI | `inspect` | ❌ `mcp__dart__get_widget_tree` |
| Tap/swipe/screenshot | `tap`, `swipe`, `screenshot` | ❌ Dart MCP (lacks these) |

#### Why flutter-skill is Superior

- ✅ **Complete UI automation**: tap, swipe, screenshot, input
- ✅ **VM Service protocol**: Full access to app internals
- ✅ **All testing needs**: Lifecycle + UI + debugging in ONE tool
- ✅ **100% capability**: vs Dart MCP's ~40%

**Dart MCP limitations**:
- ❌ No tap/click
- ❌ No swipe/scroll
- ❌ No screenshot
- ❌ No text input
- ❌ Read-only inspection
- ❌ Only ~40% of testing needs

#### Launch Configuration

**ALWAYS include VM Service flag when launching:**

```bash
# Correct
launch_app(
  project_path: ".",
  device_id: "iPhone 16 Pro",
  extra_args: ["--vm-service-port=50000"]  # ← Essential for Flutter 3.x
)

# Wrong
mcp__dart__launch_app(...)  # ❌ Don't use this
```

#### Exception Handling

If `launch_app` shows "Found DTD URI but no VM Service URI" error:
1. ✅ Add `extra_args: ["--vm-service-port=50000"]`
2. ❌ DO NOT switch to Dart MCP
3. ✅ Retry with VM Service enabled

See `FLUTTER_3X_COMPATIBILITY.md` for details.

---

## Project Rules

- Do not include "Co-Authored-By: Claude" in commit messages
- Always update CHANGELOG.md when releasing
- Keep release notes concise but informative
- Test on all platforms before major releases
- **CRITICAL**: For Flutter testing, ALWAYS use flutter-skill, NEVER Dart MCP
