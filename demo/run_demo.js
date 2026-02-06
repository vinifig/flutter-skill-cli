#!/usr/bin/env node

/**
 * Flutter Skill Test Indicators Demo Script
 *
 * This script demonstrates all visual indicators in sequence:
 * 1. Tap indicators (blue circles)
 * 2. Text input indicators (green borders)
 * 3. Long press indicators (orange rings)
 * 4. Swipe indicators (purple arrows)
 * 5. Drag indicators (purple trails)
 *
 * Prerequisites:
 * 1. Install flutter-skill-mcp: npm i -g flutter-skill-mcp
 * 2. Configure MCP in Claude/Cursor
 * 3. Start the demo app (see instructions below)
 *
 * Usage:
 * node demo/run_demo.js
 */

const readline = require('readline');

// Create readline interface for user input
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

function question(prompt) {
  return new Promise((resolve) => {
    rl.question(prompt, resolve);
  });
}

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function main() {
  console.log('╔════════════════════════════════════════════════════════════╗');
  console.log('║     Flutter Skill Test Indicators Demo                    ║');
  console.log('╚════════════════════════════════════════════════════════════╝');
  console.log('');
  console.log('This demo will showcase visual indicators for:');
  console.log('  • Tap (blue circles)');
  console.log('  • Text Input (green borders)');
  console.log('  • Long Press (orange rings)');
  console.log('  • Swipe (purple arrows)');
  console.log('  • Drag (purple trails)');
  console.log('');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');

  // Step 1: Check if app is running
  console.log('📱 STEP 1: Start the demo app');
  console.log('');
  console.log('Open a new terminal and run:');
  console.log('  cd /Users/cw/development/flutter-skill');
  console.log('  flutter run demo/test_indicators_demo.dart -d "iPhone 16 Pro"');
  console.log('');
  console.log('Or for Android:');
  console.log('  flutter run demo/test_indicators_demo.dart -d emulator-5554');
  console.log('');

  await question('Press Enter when the app is running...');
  console.log('');

  // Step 2: Instructions for using Claude/Cursor
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('🤖 STEP 2: Run commands in Claude/Cursor');
  console.log('');
  console.log('Copy and paste these commands ONE BY ONE into Claude or Cursor:');
  console.log('');
  console.log('─────────────────────────────────────────────────────────');
  console.log('');

  const commands = [
    {
      title: '1️⃣ Enable Test Indicators (Detailed Mode)',
      command: 'flutter-skill.enable_test_indicators({ enabled: true, style: "detailed" })',
      description: 'This enables visual indicators with maximum detail'
    },
    {
      title: '2️⃣ Connect to Running App',
      command: 'flutter-skill.scan_and_connect()',
      description: 'Automatically finds and connects to the demo app'
    },
    {
      title: '3️⃣ Demo: Tap Indicator (Blue Circles)',
      command: 'flutter-skill.tap({ key: "button_1" })',
      description: 'Watch for expanding blue circle animation'
    },
    {
      title: '',
      command: 'await new Promise(r => setTimeout(r, 2000)); flutter-skill.tap({ key: "button_2" })',
      description: 'Tap second button (2 second delay)'
    },
    {
      title: '',
      command: 'await new Promise(r => setTimeout(r, 2000)); flutter-skill.tap({ key: "button_3" })',
      description: 'Tap third button (2 second delay)'
    },
    {
      title: '4️⃣ Demo: Text Input Indicator (Green Borders)',
      command: 'flutter-skill.enter_text({ key: "email_field", text: "demo@flutter-skill.dev" })',
      description: 'Watch for green border highlight around email field'
    },
    {
      title: '',
      command: 'await new Promise(r => setTimeout(r, 2000)); flutter-skill.enter_text({ key: "password_field", text: "MySecretPassword123" })',
      description: 'Enter password (2 second delay)'
    },
    {
      title: '5️⃣ Demo: Long Press Indicator (Orange Ring)',
      command: 'flutter-skill.long_press({ key: "long_press_button", duration: 1000 })',
      description: 'Watch for expanding orange ring for 1 second'
    },
    {
      title: '6️⃣ Demo: Swipe Indicator (Purple Arrow Trail)',
      command: 'await new Promise(r => setTimeout(r, 2000)); flutter-skill.swipe({ direction: "up", distance: 150 })',
      description: 'Watch for purple arrow from bottom to top (2s delay)'
    },
    {
      title: '',
      command: 'await new Promise(r => setTimeout(r, 2000)); flutter-skill.swipe({ direction: "down", distance: 150 })',
      description: 'Swipe down (2 second delay)'
    },
    {
      title: '',
      command: 'await new Promise(r => setTimeout(r, 2000)); flutter-skill.swipe({ direction: "left", distance: 150 })',
      description: 'Swipe left (2 second delay)'
    },
    {
      title: '',
      command: 'await new Promise(r => setTimeout(r, 2000)); flutter-skill.swipe({ direction: "right", distance: 150 })',
      description: 'Swipe right (2 second delay)'
    },
    {
      title: '7️⃣ Demo: Drag Indicator (Purple Movement Trail)',
      command: 'await new Promise(r => setTimeout(r, 2000)); flutter-skill.drag({ from_key: "item_0", to_key: "item_4" })',
      description: 'Watch purple trail from item 1 to item 5 (2s delay)'
    },
    {
      title: '',
      command: 'await new Promise(r => setTimeout(r, 2000)); flutter-skill.drag({ from_key: "item_4", to_key: "item_0" })',
      description: 'Drag back from item 5 to item 1 (2 second delay)'
    },
    {
      title: '8️⃣ Take Screenshot',
      command: 'flutter-skill.screenshot()',
      description: 'Capture final state'
    },
    {
      title: '9️⃣ Check Indicator Status',
      command: 'flutter-skill.get_indicator_status()',
      description: 'Verify indicators are enabled'
    },
    {
      title: '🔟 Disable Indicators (Optional)',
      command: 'flutter-skill.enable_test_indicators({ enabled: false })',
      description: 'Turn off visual indicators'
    }
  ];

  for (let i = 0; i < commands.length; i++) {
    const cmd = commands[i];

    if (cmd.title) {
      console.log('');
      console.log(cmd.title);
    }

    console.log(`   ${cmd.command}`);
    console.log(`   💡 ${cmd.description}`);

    if (i < commands.length - 1) {
      await question('   ➤ Press Enter to see next command...\n');
    }
  }

  console.log('');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('🎬 STEP 3: Screen Recording Tips');
  console.log('');
  console.log('For macOS:');
  console.log('  1. Press Cmd+Shift+5 to open Screenshot toolbar');
  console.log('  2. Select "Record Selected Portion"');
  console.log('  3. Select the iOS Simulator window');
  console.log('  4. Click "Record"');
  console.log('  5. Run the commands above');
  console.log('  6. Press Stop button in menu bar when done');
  console.log('');
  console.log('For Windows:');
  console.log('  1. Press Win+G to open Game Bar');
  console.log('  2. Click "Start Recording"');
  console.log('  3. Run the commands above');
  console.log('  4. Press Win+Alt+R to stop');
  console.log('');
  console.log('For OBS Studio (All platforms):');
  console.log('  1. Add "Window Capture" source');
  console.log('  2. Select Flutter app window');
  console.log('  3. Click "Start Recording"');
  console.log('  4. Run the commands above');
  console.log('  5. Click "Stop Recording"');
  console.log('');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('✨ Demo complete!');
  console.log('');
  console.log('What you should have seen:');
  console.log('  ✅ Blue circles expanding on taps');
  console.log('  ✅ Green borders flashing on text input');
  console.log('  ✅ Orange ring growing during long press');
  console.log('  ✅ Purple arrows showing swipe directions');
  console.log('  ✅ Purple trails following drag movements');
  console.log('  ✅ Action hints at top of screen');
  console.log('');
  console.log('📹 Your video is ready for sharing!');
  console.log('');

  rl.close();
}

main().catch(console.error);
