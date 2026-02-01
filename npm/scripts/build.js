#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const rootDir = path.join(__dirname, '..', '..');
const npmDir = path.join(__dirname, '..');
const dartDir = path.join(npmDir, 'dart');

// Files to copy
const filesToCopy = [
  'pubspec.yaml',
  'lib/flutter_skill.dart',
  'lib/src/flutter_skill_client.dart',
  'lib/src/cli/server.dart',
  'lib/src/cli/setup.dart',
  'lib/src/cli/launch.dart',
  'lib/src/cli/inspect.dart',
  'lib/src/cli/act.dart',
  'bin/server.dart',
];

// Create directories
function mkdirp(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

// Copy file
function copyFile(src, dest) {
  mkdirp(path.dirname(dest));
  fs.copyFileSync(src, dest);
  console.log(`Copied: ${path.relative(rootDir, src)} -> ${path.relative(npmDir, dest)}`);
}

// Main
console.log('Building npm package...\n');

// Clean dart directory
if (fs.existsSync(dartDir)) {
  fs.rmSync(dartDir, { recursive: true });
}
mkdirp(dartDir);

// Copy files
for (const file of filesToCopy) {
  const src = path.join(rootDir, file);
  const dest = path.join(dartDir, file);
  if (fs.existsSync(src)) {
    copyFile(src, dest);
  } else {
    console.warn(`Warning: ${file} not found`);
  }
}

// Update version in package.json from pubspec.yaml
const pubspec = fs.readFileSync(path.join(rootDir, 'pubspec.yaml'), 'utf8');
const versionMatch = pubspec.match(/version:\s*(\S+)/);
if (versionMatch) {
  const packageJson = JSON.parse(fs.readFileSync(path.join(npmDir, 'package.json'), 'utf8'));
  packageJson.version = versionMatch[1];
  fs.writeFileSync(path.join(npmDir, 'package.json'), JSON.stringify(packageJson, null, 2) + '\n');
  console.log(`\nUpdated package.json version to ${versionMatch[1]}`);
}

console.log('\nBuild complete!');
