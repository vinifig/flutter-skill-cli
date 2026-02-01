# Flutter Skill (flutter-skill)

AI Agent Bridge for Flutter Apps - Connect Claude, Cursor, and other AI agents to running Flutter applications via the Dart VM Service Protocol.

## Example Usage

```json
{
    "features": {
        "ghcr.io/ai-dashboad/flutter-skill/flutter-skill:latest": {}
    }
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | Version of flutter-skill to install | string | latest |

## What This Feature Does

This feature installs the Flutter Skill CLI tool, which provides:

- **MCP Server** - JSON-RPC interface for AI agents (Claude, Cursor, Windsurf)
- **UI Inspection** - View widget tree and properties
- **Actions** - Tap, scroll, enter text in Flutter apps
- **Screenshots** - Capture app state for verification
- **Navigation** - Track routes and navigation stack

## MCP Configuration

After installation, configure your AI agent:

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

## Links

- [Documentation](https://github.com/ai-dashboad/flutter-skill)
- [pub.dev Package](https://pub.dev/packages/flutter_skill)
- [npm Package](https://www.npmjs.com/package/@anthropic/flutter-skill)
