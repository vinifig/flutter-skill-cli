#!/bin/bash
# Install tool priority rules to Claude Code configuration

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}Installing flutter-skill tool priority rules...${NC}"
echo ""

# Get project root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROMPTS_DIR="$PROJECT_ROOT/docs/prompts"

# Claude Code directories
CLAUDE_DIR="$HOME/.claude"
CLAUDE_PROMPTS="$CLAUDE_DIR/prompts"

# Create directories if they don't exist
echo "Creating Claude prompts directory..."
mkdir -p "$CLAUDE_PROMPTS"

# Copy tool priority prompt
echo "Installing tool-priority.md..."
cp "$PROMPTS_DIR/tool-priority.md" "$CLAUDE_PROMPTS/flutter-tool-priority.md"

echo -e "${GREEN}✅ Tool priority rules installed!${NC}"
echo ""
echo "Installed files:"
echo "  • $CLAUDE_PROMPTS/flutter-tool-priority.md"
echo ""
echo -e "${YELLOW}📝 What this does:${NC}"
echo "  • Claude Code will now ALWAYS prioritize flutter-skill over Dart MCP"
echo "  • Applies to ALL Flutter testing scenarios"
echo "  • No manual tool selection needed"
echo ""
echo -e "${GREEN}✨ Ready to use!${NC}"
echo "Next time you ask Claude to test a Flutter app, it will automatically:"
echo "  1. Use flutter-skill tools"
echo "  2. Add --vm-service-port=50000 flag"
echo "  3. Never suggest Dart MCP for Flutter testing"
echo ""
