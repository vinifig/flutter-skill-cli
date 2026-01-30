class FlutterSkill < Formula
  desc "MCP Server for Flutter app automation - AI Agent control for Flutter apps"
  homepage "https://github.com/ai-dashboad/flutter-skill"
  url "https://github.com/ai-dashboad/flutter-skill/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"
  license "MIT"

  depends_on "dart-lang/dart/dart" => :recommended

  def install
    # Install Dart source files
    libexec.install Dir["*"]

    # Create wrapper script
    (bin/"flutter-skill").write <<~EOS
      #!/bin/bash
      cd "#{libexec}"
      exec dart run bin/flutter_skill.dart "$@"
    EOS

    # Create MCP server wrapper
    (bin/"flutter-skill-mcp").write <<~EOS
      #!/bin/bash
      cd "#{libexec}"
      exec dart run bin/server.dart "$@"
    EOS
  end

  def post_install
    # Get pub dependencies
    system "dart", "pub", "get", chdir: libexec
  end

  def caveats
    <<~EOS
      flutter-skill requires Flutter SDK for full functionality.
      Install Flutter: https://docs.flutter.dev/get-started/install

      MCP Configuration:
        {
          "flutter-skill": {
            "command": "flutter-skill-mcp"
          }
        }

      CLI Usage:
        flutter-skill launch /path/to/flutter/project
        flutter-skill inspect
        flutter-skill act tap "button_key"
    EOS
  end

  test do
    assert_match "flutter-skill", shell_output("#{bin}/flutter-skill --help 2>&1", 1)
  end
end
