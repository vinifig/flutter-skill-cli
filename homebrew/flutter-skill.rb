class FlutterSkill < Formula
  desc "MCP Server for Flutter app automation - AI Agent control for Flutter apps"
  homepage "https://github.com/ai-dashboad/flutter-skill"
  url "https://github.com/ai-dashboad/flutter-skill/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "2b1afa456eacc6ad555678346eed8e7d7b9ea5c0f113e9cd1f47f2ff53bd2385"
  license "MIT"

  depends_on "dart-lang/dart/dart" => :recommended

  def install
    # Install Dart source files
    libexec.install Dir["*"]

    # Create wrapper script that handles pub get on first run
    (bin/"flutter-skill").write <<~EOS
      #!/bin/bash
      cd "#{libexec}"
      # Run flutter pub get if .dart_tool doesn't exist or is incomplete
      if [ ! -f ".dart_tool/package_config.json" ] || ! grep -q "flutter_skill" ".dart_tool/package_config.json" 2>/dev/null; then
        if command -v flutter &> /dev/null; then
          flutter pub get >/dev/null 2>&1
        fi
      fi
      exec dart run bin/flutter_skill.dart "$@"
    EOS

    # Create MCP server wrapper
    (bin/"flutter-skill-mcp").write <<~EOS
      #!/bin/bash
      cd "#{libexec}"
      # Run flutter pub get if .dart_tool doesn't exist or is incomplete
      if [ ! -f ".dart_tool/package_config.json" ] || ! grep -q "flutter_skill" ".dart_tool/package_config.json" 2>/dev/null; then
        if command -v flutter &> /dev/null; then
          flutter pub get >/dev/null 2>&1
        fi
      fi
      exec dart run bin/server.dart "$@"
    EOS
  end

  def post_install
    # Try flutter pub get first (preferred for Flutter packages)
    # Fall back to dart pub get if flutter is not available
    if system("which flutter > /dev/null 2>&1")
      system "flutter", "pub", "get", chdir: libexec
    else
      ohai "Flutter not found, skipping pub get. Run 'flutter pub get' in #{libexec} after installing Flutter."
    end
  end

  def caveats
    <<~EOS
      flutter-skill requires Flutter SDK for full functionality.
      Install Flutter: https://docs.flutter.dev/get-started/install

      After installing Flutter, run:
        cd #{libexec} && flutter pub get

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
