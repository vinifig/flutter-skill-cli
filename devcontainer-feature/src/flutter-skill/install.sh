#!/bin/bash
set -e

VERSION="${VERSION:-latest}"

echo "Installing Flutter Skill ${VERSION}..."

# Install via npm (most portable method)
if command -v npm &> /dev/null; then
    if [ "$VERSION" = "latest" ]; then
        npm install -g @anthropic/flutter-skill
    else
        npm install -g @anthropic/flutter-skill@$VERSION
    fi
    echo "Flutter Skill installed via npm"
elif command -v dart &> /dev/null; then
    # Alternative: Use Dart pub global activate
    dart pub global activate flutter_skill
    echo "Flutter Skill installed via Dart pub"
else
    echo "Error: Neither npm nor dart is available. Please install one of them first."
    exit 1
fi

echo ""
echo "Flutter Skill installation complete!"
echo ""
echo "MCP Configuration (add to your AI agent config):"
echo '{'
echo '  "mcpServers": {'
echo '    "flutter-skill": {'
echo '      "command": "flutter-skill",'
echo '      "args": ["server"]'
echo '    }'
echo '  }'
echo '}'
