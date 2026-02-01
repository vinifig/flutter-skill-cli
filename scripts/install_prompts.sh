#!/bin/bash

# Install Flutter-Skill Auto-Priority Prompts
# 安装 Flutter-Skill 自动优先级提示配置

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Installing Flutter-Skill Auto-Priority Prompts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# 1. Install project-level prompt
echo "📁 [1/2] Installing project-level prompt..."
if [ -f "docs/prompts/flutter-testing.md" ]; then
  mkdir -p .claude/prompts
  cp docs/prompts/flutter-testing.md .claude/prompts/
  echo "✅ Copied docs/prompts/flutter-testing.md → .claude/prompts/"
else
  echo "❌ docs/prompts/flutter-testing.md not found"
  exit 1
fi

# 2. Install global prompt
echo
echo "🌐 [2/2] Installing global prompt..."
GLOBAL_PROMPT="$HOME/.claude/prompts/auto-flutter-skill.md"

if [ -f "$GLOBAL_PROMPT" ]; then
  echo "⚠️  Global prompt already exists: $GLOBAL_PROMPT"
  echo "   Skipping installation (delete it first if you want to reinstall)"
else
  mkdir -p "$HOME/.claude/prompts"
  cat > "$GLOBAL_PROMPT" << 'EOF'
# Global Flutter-Skill Auto-Priority Configuration

## Project Detection

When current working directory contains ANY of:
- `pubspec.yaml` with `flutter:` dependency
- `lib/main.dart` file
- `ios/` or `android/` directories
- `.flutter_skill_uri` file (app already running)

**→ You are in a Flutter project. Prioritize flutter-skill MCP tools.**

## Automatic Tool Selection

### High-Priority Triggers (Auto-Use flutter-skill)

**English:**
test app, test ui, verify feature, check button, iOS simulator, Android emulator,
launch app, E2E test, integration test, UI automation

**中文:**
测试应用, 测试功能, 验证界面, 检查按钮, iOS测试, Android测试,
模拟器测试, 启动应用, 集成测试, 界面测试, 自动化测试

### Decision Matrix

- UI Testing (screen, button, UI, 界面, 按钮) → ✅ flutter-skill
- Platform Testing (iOS, Android, simulator, 模拟器) → ✅ flutter-skill
- Unit Testing (function, logic, 函数, 逻辑) → ❌ flutter test
- Code Analysis (analyze, read, 分析) → ❌ Read/Grep

See full documentation at: https://pub.dev/packages/flutter_skill
EOF
  echo "✅ Created global prompt: $GLOBAL_PROMPT"
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Installation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "📝 What was installed:"
echo "  ✓ Project-level: .claude/prompts/flutter-testing.md"
echo "  ✓ Global-level: ~/.claude/prompts/auto-flutter-skill.md"
echo
echo "💡 Test it by asking Claude Code:"
echo "   • '测试应用' or 'test the app'"
echo "   • '在iOS模拟器测试' or 'test on iOS simulator'"
echo
echo "🔍 Verify configuration:"
echo "   ./scripts/verify_auto_priority.sh"
echo
