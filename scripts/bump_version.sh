#!/bin/bash
# Bump version across all packages

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.4.0"
    exit 1
fi

VERSION=$1

echo "🔄 Updating version to $VERSION across all packages..."
echo ""

# 1. pubspec.yaml
echo "📦 Updating pubspec.yaml..."
sed -i.bak "s/^version: .*/version: $VERSION/" pubspec.yaml
rm -f pubspec.yaml.bak

# 2. SKILL.md
echo "📦 Updating SKILL.md..."
sed -i.bak "s/^version: .*/version: $VERSION/" SKILL.md
rm -f SKILL.md.bak

# 3. npm/package.json
if [ -f npm/package.json ]; then
    echo "📦 Updating npm/package.json..."
    sed -i.bak "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" npm/package.json
    rm -f npm/package.json.bak
fi

# 4. vscode-extension/package.json
if [ -f vscode-extension/package.json ]; then
    echo "📦 Updating vscode-extension/package.json..."
    sed -i.bak "s/\"version\": \".*\"/\"version\": \"$VERSION\"/" vscode-extension/package.json
    rm -f vscode-extension/package.json.bak
fi

# 5. intellij-plugin/build.gradle.kts
if [ -f intellij-plugin/build.gradle.kts ]; then
    echo "📦 Updating intellij-plugin/build.gradle.kts..."
    sed -i.bak "s/^version = \".*\"/version = \"$VERSION\"/" intellij-plugin/build.gradle.kts
    rm -f intellij-plugin/build.gradle.kts.bak
fi

echo ""
echo "✅ Version updated to $VERSION in all packages!"
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff"
echo "  2. Update CHANGELOG.md"
echo "  3. Commit: git commit -am 'chore: Release v$VERSION'"
echo "  4. Tag: git tag -a v$VERSION -m 'Release v$VERSION'"
echo "  5. Push: git push origin main && git push origin v$VERSION"
