#!/bin/bash
# One-command release script
#
# Usage:
#   ./scripts/release.sh 0.2.16 "Brief description of this release"

set -e

VERSION=$1
DESCRIPTION=${2:-"Release $VERSION"}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get project root (script location's parent)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

usage() {
    echo "Usage: ./scripts/release.sh <version> [description]"
    echo ""
    echo "Examples:"
    echo "  ./scripts/release.sh 0.2.16 \"Bug fixes and performance improvements\""
    echo "  ./scripts/release.sh 0.3.0 \"Major feature release\""
    echo ""
    echo "What it does:"
    echo "  1. Updates version in pubspec.yaml, package.json, etc."
    echo "  2. Adds entry to CHANGELOG.md"
    echo "  3. Commits, tags, and pushes"
    echo "  4. Triggers GitHub Actions release workflow"
    exit 1
}

confirm() {
    read -p "$1 [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# Validate arguments
if [ -z "$VERSION" ]; then
    usage
fi

# Validate version format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}❌ Invalid version format: $VERSION${NC}"
    echo "   Expected format: x.y.z (e.g., 0.2.16)"
    exit 1
fi

echo -e "${BLUE}🚀 Releasing v$VERSION${NC}"
echo ""

# Step 1: Check for uncommitted changes
echo "📋 Checking git status..."
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${YELLOW}⚠️  You have uncommitted changes:${NC}"
    git status --short
    echo ""
    if ! confirm "Continue anyway?"; then
        echo "Aborted."
        exit 0
    fi
fi

# Step 2: Sync version to all files
echo ""
echo -e "${BLUE}📦 Syncing version to all files...${NC}"

# pubspec.yaml
sed -i '' "s/^version: .*/version: $VERSION/" pubspec.yaml
echo "  ✓ pubspec.yaml"

# npm/package.json
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" npm/package.json
echo "  ✓ npm/package.json"

# vscode-extension/package.json
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" vscode-extension/package.json
echo "  ✓ vscode-extension/package.json"

# intellij-plugin/build.gradle.kts
sed -i '' "s/version = \"[^\"]*\"/version = \"$VERSION\"/" intellij-plugin/build.gradle.kts
echo "  ✓ intellij-plugin/build.gradle.kts"

# intellij-plugin/plugin.xml
sed -i '' "s/<version>[^<]*<\/version>/<version>$VERSION<\/version>/" intellij-plugin/src/main/resources/META-INF/plugin.xml
echo "  ✓ intellij-plugin/plugin.xml"

# README.md
sed -i '' "s/flutter_skill: \^[0-9.]*/flutter_skill: ^$VERSION/g" README.md
echo "  ✓ README.md"

# Step 3: Update CHANGELOG
echo ""
echo -e "${BLUE}📝 Updating CHANGELOG.md...${NC}"

CHANGELOG_ENTRY="## $VERSION

**$DESCRIPTION**

### Changes
- TODO: Add your changes here

---

"

# Prepend to CHANGELOG.md
echo "$CHANGELOG_ENTRY$(cat CHANGELOG.md)" > CHANGELOG.md
echo "  ✓ Added $VERSION entry"
echo -e "  ${YELLOW}⚠️  Edit CHANGELOG.md to add release details before confirming${NC}"

# Step 4: Show changes and confirm
echo ""
echo "📋 Changes to be committed:"
git add -A
git diff --cached --stat
echo ""

if ! confirm "Commit, tag, and push v$VERSION?"; then
    echo "Aborted. Changes are staged but not committed."
    exit 0
fi

# Step 5: Commit
echo ""
echo "💾 Committing..."
git commit -m "chore: Release v$VERSION

$DESCRIPTION"

# Step 6: Tag
echo "🏷️  Creating tag v$VERSION..."
git tag "v$VERSION"

# Step 7: Push
echo "📤 Pushing to origin..."
git push origin main --tags

echo ""
echo -e "${GREEN}✅ Released v$VERSION successfully!${NC}"
echo ""
echo "🔗 GitHub Actions: https://github.com/ai-dashboad/flutter-skill/actions"
echo ""
echo "Publishing to:"
echo "  • pub.dev"
echo "  • npm"
echo "  • VSCode Marketplace"
echo "  • JetBrains Marketplace"
echo "  • Homebrew"
