#!/usr/bin/env node

const { spawn, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const https = require('https');
const os = require('os');

// Package info
const packageJson = require('../package.json');
const VERSION = packageJson.version;

// Update check config
const CHECK_INTERVAL_HOURS = 24;
const UPDATE_CHECK_FILE = path.join(os.homedir(), '.flutter-skill', 'update-check.json');

// Paths
const cacheDir = path.join(os.homedir(), '.flutter-skill');
const binDir = path.join(cacheDir, 'bin');

// Get platform-specific binary name
function getBinaryName() {
  const platform = os.platform();
  const arch = os.arch();

  if (platform === 'darwin') {
    return arch === 'arm64' ? 'flutter-skill-macos-arm64' : 'flutter-skill-macos-x64';
  } else if (platform === 'linux') {
    return 'flutter-skill-linux-x64';
  } else if (platform === 'win32') {
    return 'flutter-skill-windows-x64.exe';
  }
  return null;
}

// Get the local binary path
function getLocalBinaryPath() {
  const binaryName = getBinaryName();
  if (!binaryName) return null;
  return path.join(binDir, `${binaryName}-v${VERSION}`);
}

// Download binary from GitHub releases
function downloadBinary(url, destPath) {
  return new Promise((resolve, reject) => {
    // Ensure directory exists
    fs.mkdirSync(path.dirname(destPath), { recursive: true });

    const file = fs.createWriteStream(destPath);

    const request = (url) => {
      https.get(url, (response) => {
        // Handle redirects
        if (response.statusCode === 302 || response.statusCode === 301) {
          request(response.headers.location);
          return;
        }

        if (response.statusCode !== 200) {
          reject(new Error(`Failed to download: ${response.statusCode}`));
          return;
        }

        response.pipe(file);
        file.on('finish', () => {
          file.close();
          // Make executable
          fs.chmodSync(destPath, 0o755);
          resolve(destPath);
        });
      }).on('error', (err) => {
        fs.unlink(destPath, () => {});
        reject(err);
      });
    };

    request(url);
  });
}

// Try to use native binary, fallback to Dart
async function main() {
  const binaryName = getBinaryName();
  const localBinaryPath = getLocalBinaryPath();

  // Try to use existing native binary
  if (localBinaryPath && fs.existsSync(localBinaryPath)) {
    runNativeBinary(localBinaryPath);
    return;
  }

  // Try to download native binary
  if (binaryName && localBinaryPath) {
    const downloadUrl = `https://github.com/ai-dashboad/flutter-skill/releases/download/v${VERSION}/${binaryName}`;

    try {
      // Download in background, don't block startup for first time
      // For now, just fall through to Dart
      // Future: implement async download with progress
      console.error(`[flutter-skill] Native binary not found, using Dart runtime`);
      console.error(`[flutter-skill] To install native binary for faster startup:`);
      console.error(`[flutter-skill]   curl -L ${downloadUrl} -o ${localBinaryPath} && chmod +x ${localBinaryPath}`);
    } catch (e) {
      // Ignore download errors, fall back to Dart
    }
  }

  // Fallback to Dart
  runWithDart();
}

// Run using native binary
function runNativeBinary(binaryPath) {
  const args = process.argv.slice(2);
  // Default to 'server' command if no args
  if (args.length === 0) {
    args.push('server');
  }

  const server = spawn(binaryPath, args, {
    stdio: 'inherit'
  });

  server.on('close', (code) => {
    process.exit(code || 0);
  });

  process.on('SIGINT', () => server.kill('SIGINT'));
  process.on('SIGTERM', () => server.kill('SIGTERM'));
}

// Run using Dart
function runWithDart() {
  const dartDir = path.join(__dirname, '..', 'dart');
  const serverScript = path.join(dartDir, 'bin', 'server.dart');

  // Check if Dart is installed
  try {
    execSync('dart --version', { stdio: 'ignore' });
  } catch (e) {
    console.error('Error: Dart SDK not found. Please install Flutter/Dart first.');
    console.error('  https://docs.flutter.dev/get-started/install');
    process.exit(1);
  }

  // Check if server script exists
  if (!fs.existsSync(serverScript)) {
    console.error('Error: Server script not found at:', serverScript);
    process.exit(1);
  }

  // Get dependencies silently
  try {
    const pubCmd = checkFlutter() ? 'flutter' : 'dart';
    execSync(`${pubCmd} pub get`, {
      cwd: dartDir,
      stdio: ['ignore', 'pipe', 'pipe']
    });
  } catch (e) {
    // Ignore pub get errors
  }

  // Start with Dart
  const args = process.argv.slice(2);
  if (args.length === 0) {
    args.push('server');
  }

  const dartArgs = ['run', serverScript, ...args];
  const server = spawn('dart', dartArgs, {
    cwd: dartDir,
    stdio: 'inherit'
  });

  server.on('close', (code) => {
    process.exit(code || 0);
  });

  process.on('SIGINT', () => server.kill('SIGINT'));
  process.on('SIGTERM', () => server.kill('SIGTERM'));
}

function checkFlutter() {
  try {
    execSync('flutter --version', { stdio: 'ignore' });
    return true;
  } catch (e) {
    return false;
  }
}

// Check for updates (non-blocking, runs in background)
function checkForUpdates() {
  // Only check periodically
  try {
    const checkDir = path.dirname(UPDATE_CHECK_FILE);
    if (!fs.existsSync(checkDir)) {
      fs.mkdirSync(checkDir, { recursive: true });
    }

    let lastCheck = 0;
    let skippedVersion = null;

    if (fs.existsSync(UPDATE_CHECK_FILE)) {
      try {
        const data = JSON.parse(fs.readFileSync(UPDATE_CHECK_FILE, 'utf-8'));
        lastCheck = data.lastCheck || 0;
        skippedVersion = data.skippedVersion;
      } catch {}
    }

    const now = Date.now();
    const hoursSinceLastCheck = (now - lastCheck) / (1000 * 60 * 60);

    if (hoursSinceLastCheck < CHECK_INTERVAL_HOURS) {
      return;
    }

    // Update last check time
    fs.writeFileSync(UPDATE_CHECK_FILE, JSON.stringify({
      lastCheck: now,
      skippedVersion
    }));

    // Check npm registry for latest version (async, non-blocking)
    https.get('https://registry.npmjs.org/flutter-skill-mcp', (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          const latestVersion = json['dist-tags'].latest;

          if (latestVersion && compareVersions(latestVersion, VERSION) > 0) {
            if (skippedVersion !== latestVersion) {
              console.error(`\n[flutter-skill] Update available: ${VERSION} → ${latestVersion}`);
              console.error(`[flutter-skill] Run: npm update -g flutter-skill-mcp\n`);
            }
          }
        } catch {}
      });
    }).on('error', () => {});
  } catch {}
}

function compareVersions(v1, v2) {
  const parts1 = v1.split('.').map(Number);
  const parts2 = v2.split('.').map(Number);

  for (let i = 0; i < Math.max(parts1.length, parts2.length); i++) {
    const p1 = parts1[i] || 0;
    const p2 = parts2[i] || 0;
    if (p1 > p2) return 1;
    if (p1 < p2) return -1;
  }
  return 0;
}

// Run update check in background (non-blocking)
checkForUpdates();

main().catch(console.error);
