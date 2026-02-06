#!/bin/bash

# Flutter Skill Test Indicators - Quick Demo
#
# This script helps you quickly start the demo and provides
# commands to run in Claude/Cursor for visual demonstration

set -e

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Flutter Skill Test Indicators - Quick Demo            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Step 1: Check prerequisites
echo -e "${GREEN}[1/4] Checking prerequisites...${NC}"

# Check if flutter is installed
if ! command -v flutter &> /dev/null; then
    echo -e "${YELLOW}⚠️  Flutter not found. Please install Flutter first.${NC}"
    exit 1
fi

# Check if flutter-skill is installed
if ! command -v flutter-skill &> /dev/null && ! command -v flutter_skill &> /dev/null; then
    echo -e "${YELLOW}⚠️  flutter-skill not found.${NC}"
    echo "Install it with one of:"
    echo "  npm i -g flutter-skill-mcp"
    echo "  brew install ai-dashboad/flutter-skill/flutter-skill"
    echo "  dart pub global activate flutter_skill"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites OK${NC}"
echo ""

# Step 2: List available devices
echo -e "${GREEN}[2/4] Listing available devices...${NC}"
flutter devices --machine > /tmp/flutter_devices.json 2>/dev/null || true

echo ""
echo "Available devices:"
flutter devices
echo ""

# Ask user to select device
read -p "Enter device ID (or press Enter for iOS Simulator): " DEVICE_ID

if [ -z "$DEVICE_ID" ]; then
    # Try to find iPhone simulator
    DEVICE_ID=$(flutter devices | grep "iPhone" | head -1 | awk '{print $NF}' | tr -d '()')

    if [ -z "$DEVICE_ID" ]; then
        echo -e "${YELLOW}⚠️  No iPhone simulator found. Using first available device.${NC}"
        DEVICE_ID=$(flutter devices | grep -v "No devices" | tail -1 | awk '{print $NF}' | tr -d '()')
    fi
fi

echo ""
echo -e "${GREEN}Selected device: $DEVICE_ID${NC}"
echo ""

# Step 3: Start the demo app
echo -e "${GREEN}[3/4] Starting demo app...${NC}"
echo ""
echo "Starting Flutter app on $DEVICE_ID..."
echo "This will take a moment..."
echo ""

# Run in background
flutter run \
    demo/test_indicators_demo.dart \
    -d "$DEVICE_ID" \
    --vm-service-port=50000 \
    > /tmp/flutter_demo.log 2>&1 &

FLUTTER_PID=$!

echo "Flutter app PID: $FLUTTER_PID"
echo ""

# Wait for app to start
echo "Waiting for app to start..."
sleep 5

# Check if still running
if ! ps -p $FLUTTER_PID > /dev/null; then
    echo -e "${YELLOW}⚠️  Flutter app failed to start. Check log:${NC}"
    cat /tmp/flutter_demo.log
    exit 1
fi

echo -e "${GREEN}✅ Demo app started${NC}"
echo ""

# Step 4: Show commands for Claude/Cursor
echo -e "${GREEN}[4/4] Ready for demo!${NC}"
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "📋 Copy these commands to Claude/Cursor (one at a time):"
echo ""
echo -e "${YELLOW}# 1. Enable visual indicators${NC}"
echo "flutter-skill.enable_test_indicators({ enabled: true, style: \"detailed\" })"
echo ""

echo -e "${YELLOW}# 2. Connect to the app${NC}"
echo "flutter-skill.scan_and_connect()"
echo ""

echo -e "${YELLOW}# 3. Demo: Tap (Blue Circles)${NC}"
echo "flutter-skill.tap({ key: \"button_1\" })"
echo "flutter-skill.tap({ key: \"button_2\" })"
echo "flutter-skill.tap({ key: \"button_3\" })"
echo ""

echo -e "${YELLOW}# 4. Demo: Text Input (Green Borders)${NC}"
echo "flutter-skill.enter_text({ key: \"email_field\", text: \"demo@flutter-skill.dev\" })"
echo "flutter-skill.enter_text({ key: \"password_field\", text: \"MyPassword123\" })"
echo ""

echo -e "${YELLOW}# 5. Demo: Long Press (Orange Ring)${NC}"
echo "flutter-skill.long_press({ key: \"long_press_button\", duration: 1000 })"
echo ""

echo -e "${YELLOW}# 6. Demo: Swipe (Purple Arrows)${NC}"
echo "flutter-skill.swipe({ direction: \"up\", distance: 150 })"
echo "flutter-skill.swipe({ direction: \"down\", distance: 150 })"
echo "flutter-skill.swipe({ direction: \"left\", distance: 150 })"
echo "flutter-skill.swipe({ direction: \"right\", distance: 150 })"
echo ""

echo -e "${YELLOW}# 7. Demo: Drag (Purple Trail)${NC}"
echo "flutter-skill.drag({ from_key: \"item_0\", to_key: \"item_4\" })"
echo "flutter-skill.drag({ from_key: \"item_4\", to_key: \"item_0\" })"
echo ""

echo -e "${YELLOW}# 8. Screenshot${NC}"
echo "flutter-skill.screenshot()"
echo ""

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "🎬 Pro Tip: Start screen recording BEFORE running commands!"
echo ""
echo "macOS: Cmd+Shift+5 → Record Selected Portion"
echo "Windows: Win+G → Start Recording"
echo ""
echo -e "${GREEN}Press Ctrl+C when done to stop the app${NC}"
echo ""

# Wait for user to stop
trap "kill $FLUTTER_PID 2>/dev/null; echo ''; echo 'Demo stopped. Goodbye!'; exit 0" INT

# Keep script running
wait $FLUTTER_PID
