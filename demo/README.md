# Flutter Skill Test Indicators Demo 🎬

This demo showcases the **visual operation tracking** feature of Flutter Skill, displaying real-time indicators for all test actions.

## 🎯 What You'll See

### 1. Tap Indicator (Blue Circles)
- Expanding blue circle animation at tap location
- Shows "Tapping 'Button Name'" hint at top

### 2. Text Input Indicator (Green Borders)
- Flashing green border around text fields
- Shows "Entering text: '...'" hint

### 3. Long Press Indicator (Orange Ring)
- Expanding orange ring during long press
- Duration-based animation

### 4. Swipe Indicator (Purple Arrow Trail)
- Purple dashed line with arrow
- Shows direction (up/down/left/right)
- Animated trail effect

### 5. Drag Indicator (Purple Movement Trail)
- Purple line connecting source and destination
- Shows "Dragging from X to Y" hint

## 🚀 Quick Start

### Option 1: Automated Demo (Recommended)

```bash
# 1. Start the demo app
cd /Users/cw/development/flutter-skill
flutter run demo/test_indicators_demo.dart -d "iPhone 16 Pro"

# 2. In another terminal, run the demo guide
node demo/run_demo.js

# 3. Follow the instructions and copy commands to Claude/Cursor
```

### Option 2: Manual Demo

```bash
# 1. Start the demo app
flutter run demo/test_indicators_demo.dart -d "iPhone 16 Pro"

# 2. In Claude/Cursor, run these commands:

# Enable indicators (detailed mode for best visibility)
flutter-skill.enable_test_indicators({
  enabled: true,
  style: "detailed"
})

# Connect to app
flutter-skill.scan_and_connect()

# Try different actions
flutter-skill.tap({ key: "button_1" })
flutter-skill.enter_text({ key: "email_field", text: "demo@example.com" })
flutter-skill.long_press({ key: "long_press_button" })
flutter-skill.swipe({ direction: "up" })
flutter-skill.drag({ from_key: "item_0", to_key: "item_4" })

# Take screenshot
flutter-skill.screenshot()
```

## 📹 Recording the Demo

### macOS

```bash
# Method 1: Built-in Screenshot tool
1. Press Cmd+Shift+5
2. Select "Record Selected Portion"
3. Select iOS Simulator window
4. Click Record
5. Run demo commands
6. Click Stop in menu bar

# Method 2: QuickTime
1. Open QuickTime Player
2. File → New Screen Recording
3. Select region or full screen
4. Run demo commands
5. Stop recording
```

### Windows

```bash
# Windows Game Bar
1. Press Win+G
2. Click "Start Recording"
3. Run demo commands
4. Press Win+Alt+R to stop
```

### Cross-Platform (OBS Studio)

```bash
# Download OBS Studio: https://obsproject.com/

1. Add "Window Capture" source
2. Select Flutter app window
3. Click "Start Recording"
4. Run demo commands
5. Click "Stop Recording"
```

## 🎨 Indicator Styles

### Minimal
```javascript
flutter-skill.enable_test_indicators({ style: "minimal" })
```
- Smallest size
- Fastest animation
- No action hints
- Best for performance

### Standard (Default)
```javascript
flutter-skill.enable_test_indicators({ style: "standard" })
```
- Medium size
- Normal animation speed
- 1-second action hints
- Recommended for demos

### Detailed
```javascript
flutter-skill.enable_test_indicators({ style: "detailed" })
```
- Largest size
- Slowest animation (easier to see)
- 2-second action hints + debug info
- **Best for video recording** ⭐

## 📊 Demo Timeline

Here's what the full demo covers:

| Time | Action | Visual Effect |
|------|--------|--------------|
| 0:00 | Enable indicators | Confirmation message |
| 0:05 | Connect to app | App loads |
| 0:10 | Tap button 1 | Blue circle expands |
| 0:12 | Tap button 2 | Blue circle expands |
| 0:14 | Tap button 3 | Blue circle expands |
| 0:16 | Enter email | Green border flashes |
| 0:20 | Enter password | Green border flashes |
| 0:24 | Long press | Orange ring expands |
| 0:28 | Swipe up | Purple arrow ↑ |
| 0:30 | Swipe down | Purple arrow ↓ |
| 0:32 | Swipe left | Purple arrow ← |
| 0:34 | Swipe right | Purple arrow → |
| 0:36 | Drag item | Purple trail |
| 0:40 | Screenshot | Capture final state |

**Total Duration:** ~45 seconds

## 🎥 Sample Video Script

If you're creating a narrated video, here's a suggested script:

```
"Let me show you Flutter Skill's visual test indicators feature.

First, I'll enable the indicators in detailed mode for maximum visibility.
[Run: enable_test_indicators]

Now I'll connect to my Flutter app.
[Run: scan_and_connect]

Watch what happens when I tap a button...
[Run: tap]
See the blue expanding circle? That shows exactly where the tap occurred.

Let's try text input...
[Run: enter_text]
Notice the green border flashing around the field.

Here's a long press...
[Run: long_press]
The orange ring expands for the duration of the press.

Now for swipes - watch the purple arrows...
[Run: swipe up/down/left/right]
Each direction is clearly indicated.

And finally, a drag operation...
[Run: drag]
The purple trail shows the exact movement path.

These indicators make it incredibly easy to visualize and debug
your automated Flutter tests!"
```

## 🛠️ Troubleshooting

### Indicators not showing?

```javascript
// Check status
flutter-skill.get_indicator_status()

// Re-enable
flutter-skill.enable_test_indicators({
  enabled: true,
  style: "detailed"
})
```

### App not connecting?

```bash
# Check if app is running
flutter devices

# Restart app with VM Service port
flutter run demo/test_indicators_demo.dart \
  -d "iPhone 16 Pro" \
  --vm-service-port=50000
```

### Indicators too small/fast?

```javascript
// Use detailed style
flutter-skill.enable_test_indicators({ style: "detailed" })
```

## 📸 Example Screenshots

After running the demo, you should have screenshots showing:
- Blue tap circles
- Green text input highlights
- Orange long press rings
- Purple swipe arrows
- Purple drag trails
- Action hints at the top

## 🚀 Next Steps

1. **Record your demo video**
2. **Share on Twitter** using the pre-written tweet
3. **Post on YouTube/LinkedIn** showcasing the feature
4. **Add to your README** to demonstrate testing capabilities

## 📝 Notes

- The demo app is designed specifically to showcase all indicator types
- All buttons and fields have proper `key` attributes for easy targeting
- The layout is optimized for both portrait and landscape orientations
- Works on iOS Simulator, Android Emulator, and real devices

---

**Happy Recording!** 🎬✨

If you have any questions, check the main README or open an issue on GitHub.
