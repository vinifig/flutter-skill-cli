class FlutterSkill < Formula
  desc "MCP Server for Flutter app automation - AI Agent control for Flutter apps"
  homepage "https://github.com/ai-dashboad/flutter-skill"
  version "0.2.9"
  license "MIT"

  # Platform-specific native binaries
  on_macos do
    on_arm do
      url "https://github.com/ai-dashboad/flutter-skill/releases/download/v0.2.9/flutter-skill-macos-arm64"
      sha256 "PLACEHOLDER_ARM64_SHA256"
    end
    on_intel do
      url "https://github.com/ai-dashboad/flutter-skill/releases/download/v0.2.9/flutter-skill-macos-x64"
      sha256 "PLACEHOLDER_X64_SHA256"
    end
  end

  on_linux do
    url "https://github.com/ai-dashboad/flutter-skill/releases/download/v0.2.9/flutter-skill-linux-x64"
    sha256 "PLACEHOLDER_LINUX_SHA256"
  end

  def install
    # Install the native binary directly
    bin.install Dir["flutter-skill-*"].first => "flutter-skill"
  end

  def caveats
    <<~EOS
      flutter-skill is now installed as a native binary for instant startup!

      MCP Configuration (add to ~/.claude/settings.json):
        {
          "mcpServers": {
            "flutter-skill": {
              "command": "flutter-skill",
              "args": ["server"]
            }
          }
        }

      CLI Usage:
        flutter-skill launch /path/to/flutter/project
        flutter-skill inspect
        flutter-skill act tap "button_key"

      Note: Your Flutter app needs to include the flutter_skill package.
      Add to pubspec.yaml:
        dependencies:
          flutter_skill: ^0.2.9
    EOS
  end

  test do
    assert_match "flutter-skill-mcp", shell_output("#{bin}/flutter-skill server --help 2>&1", 1)
  end
end
