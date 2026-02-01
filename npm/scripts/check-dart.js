#!/usr/bin/env node

const { execSync } = require('child_process');

function checkCommand(cmd) {
  try {
    execSync(`${cmd} --version`, { stdio: 'ignore' });
    return true;
  } catch (e) {
    return false;
  }
}

const hasDart = checkCommand('dart');
const hasFlutter = checkCommand('flutter');

if (!hasDart && !hasFlutter) {
  console.log('\n' + '='.repeat(60));
  console.log('flutter-skill-mcp requires Dart SDK');
  console.log('='.repeat(60));
  console.log('\nPlease install Flutter (includes Dart):');
  console.log('  https://docs.flutter.dev/get-started/install\n');
  console.log('Or install Dart standalone:');
  console.log('  https://dart.dev/get-dart\n');
} else if (hasDart && !hasFlutter) {
  console.log('\nNote: Flutter SDK not found. Some features may be limited.');
  console.log('Install Flutter for full functionality:');
  console.log('  https://docs.flutter.dev/get-started/install\n');
} else {
  console.log('\nflutter-skill-mcp installed successfully!');
  console.log('\nMCP Config:');
  console.log(JSON.stringify({
    "flutter-skill": {
      "command": "npx",
      "args": ["flutter-skill-mcp"]
    }
  }, null, 2));
  console.log('\n');
}
