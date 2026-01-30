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

## Project Rules

- Do not include "Co-Authored-By: Claude" in commit messages
