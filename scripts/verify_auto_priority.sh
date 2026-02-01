#!/bin/bash

# Flutter-Skill Auto-Priority Configuration Verification Script
# 验证自动优先级配置是否正确设置

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Flutter-Skill Auto-Priority Configuration Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

PASS_COUNT=0
FAIL_COUNT=0

check_pass() {
  echo "✅ $1"
  ((PASS_COUNT++))
}

check_fail() {
  echo "❌ $1"
  ((FAIL_COUNT++))
}

# 1. Check SKILL.md frontmatter
echo "📋 [1/6] Checking SKILL.md configuration..."
if grep -q "priority: high" SKILL.md && grep -q "auto_activate: true" SKILL.md; then
  check_pass "SKILL.md has enhanced frontmatter (priority: high, auto_activate: true)"
else
  check_fail "SKILL.md missing priority/auto_activate configuration"
fi

# 2. Check for Chinese triggers
echo
echo "🇨🇳 [2/6] Checking Chinese trigger words..."
if grep -q "测试应用" SKILL.md && grep -q "验证功能" SKILL.md; then
  check_pass "SKILL.md includes Chinese triggers (测试应用, 验证功能, etc.)"
else
  check_fail "SKILL.md missing Chinese trigger words"
fi

# 3. Check project-level prompts
echo
echo "📁 [3/6] Checking project-level prompts..."
if [ -f ".claude/prompts/flutter-testing.md" ]; then
  check_pass "Project-level prompt exists: .claude/prompts/flutter-testing.md"
else
  check_fail "Missing .claude/prompts/flutter-testing.md"
fi

# 4. Check global prompts
echo
echo "🌐 [4/6] Checking global prompts..."
if [ -f "$HOME/.claude/prompts/auto-flutter-skill.md" ]; then
  check_pass "Global prompt exists: ~/.claude/prompts/auto-flutter-skill.md"
else
  check_fail "Missing ~/.claude/prompts/auto-flutter-skill.md"
fi

# 5. Check MCP server configuration
echo
echo "⚙️  [5/6] Checking MCP server configuration..."
if [ -f "$HOME/.claude/settings.json" ]; then
  if grep -q "flutter-skill" "$HOME/.claude/settings.json"; then
    check_pass "MCP server configured in ~/.claude/settings.json"
  else
    check_fail "flutter-skill not found in ~/.claude/settings.json"
  fi
else
  check_fail "Missing ~/.claude/settings.json"
fi

# 6. Check if flutter-skill command is available
echo
echo "🛠️  [6/6] Checking flutter-skill CLI availability..."
if command -v flutter-skill-fast &> /dev/null; then
  VERSION=$(flutter-skill-fast --version 2>/dev/null | head -1 || echo "unknown")
  check_pass "flutter-skill-fast command available ($VERSION)"
elif command -v flutter_skill &> /dev/null; then
  check_pass "flutter_skill command available"
else
  check_fail "flutter-skill command not found in PATH"
fi

# Summary
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Passed: $PASS_COUNT"
echo "❌ Failed: $FAIL_COUNT"
echo

if [ $FAIL_COUNT -eq 0 ]; then
  echo "🎉 All checks passed! Auto-priority configuration is complete."
  echo
  echo "💡 Test it by asking Claude Code:"
  echo "   - '测试应用' or 'test the app'"
  echo "   - '在iOS模拟器测试' or 'test on iOS simulator'"
  echo "   - '验证登录功能' or 'verify login feature'"
  echo
  echo "Claude should automatically use flutter-skill MCP tools!"
  exit 0
else
  echo "⚠️  Some checks failed. Please review the errors above."
  echo
  echo "📖 See AUTO_PRIORITY_SETUP.md for troubleshooting guide."
  exit 1
fi
