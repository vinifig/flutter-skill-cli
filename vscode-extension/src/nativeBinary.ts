import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import * as https from 'https';

const CACHE_DIR = path.join(os.homedir(), '.flutter-skill');
const BIN_DIR = path.join(CACHE_DIR, 'bin');

/**
 * Get platform-specific binary name
 */
export function getBinaryName(): string | null {
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

/**
 * Get the local binary path for a specific version
 */
export function getLocalBinaryPath(version: string): string | null {
    const binaryName = getBinaryName();
    if (!binaryName) return null;
    return path.join(BIN_DIR, `${binaryName}-v${version}`);
}

/**
 * Check if native binary exists for the given version
 */
export function hasNativeBinary(version: string): boolean {
    const binaryPath = getLocalBinaryPath(version);
    return binaryPath !== null && fs.existsSync(binaryPath);
}

/**
 * Download native binary from GitHub releases
 */
export async function downloadNativeBinary(
    version: string,
    outputChannel: vscode.OutputChannel,
    progress?: vscode.Progress<{ message?: string; increment?: number }>
): Promise<string | null> {
    const binaryName = getBinaryName();
    if (!binaryName) {
        outputChannel.appendLine('[Native] No native binary available for this platform');
        return null;
    }

    const localPath = getLocalBinaryPath(version);
    if (!localPath) return null;

    // Already exists
    if (fs.existsSync(localPath)) {
        outputChannel.appendLine(`[Native] Binary already exists at ${localPath}`);
        return localPath;
    }

    const downloadUrl = `https://github.com/ai-dashboad/flutter-skill/releases/download/v${version}/${binaryName}`;

    outputChannel.appendLine(`[Native] Downloading from ${downloadUrl}`);
    progress?.report({ message: 'Downloading native binary...' });

    return new Promise((resolve) => {
        // Ensure directory exists
        fs.mkdirSync(path.dirname(localPath), { recursive: true });

        const file = fs.createWriteStream(localPath);

        const request = (url: string) => {
            https.get(url, (response) => {
                // Handle redirects
                if (response.statusCode === 302 || response.statusCode === 301) {
                    const redirectUrl = response.headers.location;
                    if (redirectUrl) {
                        request(redirectUrl);
                    } else {
                        outputChannel.appendLine('[Native] Redirect without location header');
                        resolve(null);
                    }
                    return;
                }

                if (response.statusCode !== 200) {
                    outputChannel.appendLine(`[Native] Download failed: HTTP ${response.statusCode}`);
                    fs.unlink(localPath, () => {});
                    resolve(null);
                    return;
                }

                const totalBytes = parseInt(response.headers['content-length'] || '0', 10);
                let downloadedBytes = 0;

                response.on('data', (chunk: Buffer) => {
                    downloadedBytes += chunk.length;
                    if (totalBytes > 0) {
                        const percent = Math.round((downloadedBytes / totalBytes) * 100);
                        progress?.report({ message: `Downloading... ${percent}%` });
                    }
                });

                response.pipe(file);

                file.on('finish', () => {
                    file.close();
                    // Make executable
                    fs.chmodSync(localPath, 0o755);
                    outputChannel.appendLine(`[Native] Downloaded to ${localPath}`);
                    resolve(localPath);
                });

                file.on('error', (err) => {
                    outputChannel.appendLine(`[Native] Write error: ${err.message}`);
                    fs.unlink(localPath, () => {});
                    resolve(null);
                });
            }).on('error', (err) => {
                outputChannel.appendLine(`[Native] Download error: ${err.message}`);
                fs.unlink(localPath, () => {});
                resolve(null);
            });
        };

        request(downloadUrl);
    });
}

/**
 * Get the best available binary path (native or fallback to dart command)
 */
export async function getBestBinaryPath(
    version: string,
    outputChannel: vscode.OutputChannel
): Promise<{ path: string; isNative: boolean }> {
    // Check if native binary exists
    const localPath = getLocalBinaryPath(version);
    if (localPath && fs.existsSync(localPath)) {
        return { path: localPath, isNative: true };
    }

    // Try to download
    const downloaded = await downloadNativeBinary(version, outputChannel);
    if (downloaded) {
        return { path: downloaded, isNative: true };
    }

    // Fallback to flutter-skill command (from PATH)
    return { path: 'flutter-skill', isNative: false };
}

/**
 * Ensure native binary is available (download if needed)
 */
export async function ensureNativeBinary(
    version: string,
    outputChannel: vscode.OutputChannel
): Promise<void> {
    if (hasNativeBinary(version)) {
        return;
    }

    await vscode.window.withProgress(
        {
            location: vscode.ProgressLocation.Notification,
            title: 'Flutter Skill',
            cancellable: false
        },
        async (progress) => {
            progress.report({ message: 'Installing native binary for faster startup...' });
            const result = await downloadNativeBinary(version, outputChannel, progress);
            if (result) {
                vscode.window.showInformationMessage('Flutter Skill native binary installed!');
            }
        }
    );
}
