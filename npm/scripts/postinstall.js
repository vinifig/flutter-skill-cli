#!/usr/bin/env node

const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');

const packageJson = require('../package.json');
const VERSION = packageJson.version;

const cacheDir = path.join(os.homedir(), '.flutter-skill');
const binDir = path.join(cacheDir, 'bin');

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

function downloadBinary(url, destPath) {
  return new Promise((resolve, reject) => {
    fs.mkdirSync(path.dirname(destPath), { recursive: true });

    const file = fs.createWriteStream(destPath);

    const request = (url) => {
      https.get(url, (response) => {
        if (response.statusCode === 302 || response.statusCode === 301) {
          request(response.headers.location);
          return;
        }

        if (response.statusCode !== 200) {
          reject(new Error(`HTTP ${response.statusCode}`));
          return;
        }

        const totalBytes = parseInt(response.headers['content-length'], 10);
        let downloadedBytes = 0;

        response.on('data', (chunk) => {
          downloadedBytes += chunk.length;
          if (totalBytes) {
            const percent = Math.round((downloadedBytes / totalBytes) * 100);
            process.stdout.write(`\r[flutter-skill] Downloading native binary... ${percent}%`);
          }
        });

        response.pipe(file);
        file.on('finish', () => {
          file.close();
          fs.chmodSync(destPath, 0o755);
          console.log('\n[flutter-skill] Native binary installed successfully!');
          resolve(destPath);
        });
      }).on('error', reject);
    };

    request(url);
  });
}

async function main() {
  const binaryName = getBinaryName();
  if (!binaryName) {
    console.log('[flutter-skill] No native binary available for this platform, using Dart runtime');
    return;
  }

  const localPath = path.join(binDir, `${binaryName}-v${VERSION}`);

  if (fs.existsSync(localPath)) {
    console.log('[flutter-skill] Native binary already installed');
    return;
  }

  const downloadUrl = `https://github.com/ai-dashboad/flutter-skill/releases/download/v${VERSION}/${binaryName}`;

  console.log(`[flutter-skill] Installing native binary for faster startup...`);

  try {
    await downloadBinary(downloadUrl, localPath);
  } catch (error) {
    console.log(`[flutter-skill] Could not download native binary (${error.message}), will use Dart runtime`);
    console.log('[flutter-skill] This is normal for new releases, Dart fallback works fine');
  }
}

main().catch(() => {
  // Silent fail - Dart fallback will work
});
