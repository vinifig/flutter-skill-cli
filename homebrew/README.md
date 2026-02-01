# Homebrew Formula for flutter-skill

## Setup Homebrew Tap

To distribute via Homebrew, create a separate repository named `homebrew-flutter-skill`:

```bash
# Create the tap repository
gh repo create ai-dashboad/homebrew-flutter-skill --public --description "Homebrew tap for flutter-skill"

# Clone and add formula
git clone https://github.com/ai-dashboad/homebrew-flutter-skill.git
cp flutter-skill.rb homebrew-flutter-skill/Formula/
cd homebrew-flutter-skill
git add . && git commit -m "Add flutter-skill formula"
git push
```

## Calculate SHA256

After creating a release, calculate the SHA256:

```bash
curl -sL https://github.com/ai-dashboad/flutter-skill/archive/refs/tags/v0.2.0.tar.gz | shasum -a 256
```

Update the `sha256` field in the formula.

## Installation (for users)

```bash
# Add the tap
brew tap ai-dashboad/flutter-skill

# Install
brew install flutter-skill

# Use
flutter-skill --help
flutter-skill-mcp  # Start MCP server
```

## MCP Configuration

```json
{
  "flutter-skill": {
    "command": "flutter-skill-mcp"
  }
}
```
