#!/bin/bash
# Flutter Skill CLI Wrapper
# Runs flutter_skill from source directory

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
dart run "$SCRIPT_DIR/bin/flutter_skill.dart" "$@"
