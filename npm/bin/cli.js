#!/usr/bin/env node

const { spawn, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

// Find the dart directory
const dartDir = path.join(__dirname, '..', 'dart');
const serverScript = path.join(dartDir, 'bin', 'server.dart');

// Check if Dart is installed
function checkDart() {
  try {
    execSync('dart --version', { stdio: 'ignore' });
    return true;
  } catch (e) {
    return false;
  }
}

// Check if Flutter is installed
function checkFlutter() {
  try {
    execSync('flutter --version', { stdio: 'ignore' });
    return true;
  } catch (e) {
    return false;
  }
}

if (!checkDart()) {
  console.error('Error: Dart SDK not found. Please install Flutter/Dart first.');
  console.error('  https://docs.flutter.dev/get-started/install');
  process.exit(1);
}

// Check if server script exists
if (!fs.existsSync(serverScript)) {
  console.error('Error: Server script not found at:', serverScript);
  process.exit(1);
}

// Get dependencies silently (redirect to stderr to not interfere with MCP JSON-RPC)
const pubCmd = checkFlutter() ? 'flutter' : 'dart';
try {
  execSync(`${pubCmd} pub get`, {
    cwd: dartDir,
    stdio: ['ignore', 'pipe', 'pipe']  // Silent - don't interfere with MCP stdin/stdout
  });
} catch (e) {
  // Log to stderr if pub get fails
  console.error('Warning: pub get failed, dependencies may be missing');
}

// Start the MCP server with proper stdio for JSON-RPC
const server = spawn('dart', ['run', serverScript], {
  cwd: dartDir,
  stdio: 'inherit'  // stdin/stdout/stderr passed through for MCP communication
});

server.on('close', (code) => {
  process.exit(code || 0);
});

// Forward signals
process.on('SIGINT', () => server.kill('SIGINT'));
process.on('SIGTERM', () => server.kill('SIGTERM'));
