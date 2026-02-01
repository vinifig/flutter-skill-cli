# Flutter Skill - IntelliJ/Android Studio Plugin

Control Flutter apps with AI agents - inspect UI, perform gestures, take screenshots.

## Features

- **Launch App**: Start Flutter app with Flutter Skill integration
- **Inspect UI**: View interactive elements and widget tree
- **Take Screenshot**: Capture app screenshots
- **MCP Server**: Start MCP server for AI agent integration

## Installation

### From Plugin Marketplace

1. Open IntelliJ IDEA or Android Studio
2. Go to Settings → Plugins → Marketplace
3. Search for "Flutter Skill"
4. Install and restart

### From ZIP (Local)

```bash
./gradlew buildPlugin
# Install from build/distributions/flutter-skill-intellij-*.zip
```

## Requirements

- IntelliJ IDEA 2023.1+ or Android Studio Hedgehog+
- Dart plugin installed
- Flutter SDK
- flutter_skill package: `dart pub global activate flutter_skill`

## Usage

### From Menu

Tools → Flutter Skill → [Action]

### From Tool Window

View → Tool Windows → Flutter Skill

## MCP Configuration

For Cursor/Windsurf:

```json
{
  "flutter-skill": {
    "command": "npx",
    "args": ["flutter-skill-mcp"]
  }
}
```

## Building

```bash
# Build plugin
./gradlew buildPlugin

# Run in sandbox IDE
./gradlew runIde

# Publish to marketplace
./gradlew publishPlugin
```

## Links

- [GitHub](https://github.com/ai-dashboad/flutter-skill)
- [pub.dev](https://pub.dev/packages/flutter_skill)
- [npm](https://www.npmjs.com/package/flutter-skill-mcp)
