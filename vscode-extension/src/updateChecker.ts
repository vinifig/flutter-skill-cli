import * as vscode from 'vscode';
import * as https from 'https';

const CHECK_INTERVAL_HOURS = 24;
const LAST_CHECK_KEY = 'flutter-skill.lastUpdateCheck';
const SKIPPED_VERSION_KEY = 'flutter-skill.skippedVersion';

interface NpmPackageInfo {
    'dist-tags': {
        latest: string;
    };
    versions: Record<string, unknown>;
}

/**
 * Check npm registry for latest version
 */
async function getLatestVersion(): Promise<string | null> {
    return new Promise((resolve) => {
        const req = https.get('https://registry.npmjs.org/flutter-skill-mcp', (res) => {
            let data = '';
            res.on('data', (chunk) => data += chunk);
            res.on('end', () => {
                try {
                    const json: NpmPackageInfo = JSON.parse(data);
                    resolve(json['dist-tags'].latest);
                } catch {
                    resolve(null);
                }
            });
        });
        req.on('error', () => resolve(null));
        req.setTimeout(5000, () => {
            req.destroy();
            resolve(null);
        });
    });
}

/**
 * Compare semantic versions
 * Returns: 1 if v1 > v2, -1 if v1 < v2, 0 if equal
 */
function compareVersions(v1: string, v2: string): number {
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

/**
 * Check for updates and notify user if new version available
 */
export async function checkForUpdates(
    currentVersion: string,
    context: vscode.ExtensionContext,
    outputChannel: vscode.OutputChannel
): Promise<void> {
    // Check if we should check (once per 24 hours)
    const lastCheck = context.globalState.get<number>(LAST_CHECK_KEY) || 0;
    const now = Date.now();
    const hoursSinceLastCheck = (now - lastCheck) / (1000 * 60 * 60);

    if (hoursSinceLastCheck < CHECK_INTERVAL_HOURS) {
        return;
    }

    // Update last check time
    await context.globalState.update(LAST_CHECK_KEY, now);

    outputChannel.appendLine('[Update] Checking for updates...');

    const latestVersion = await getLatestVersion();
    if (!latestVersion) {
        outputChannel.appendLine('[Update] Could not check for updates');
        return;
    }

    outputChannel.appendLine(`[Update] Current: ${currentVersion}, Latest: ${latestVersion}`);

    // Check if update available
    if (compareVersions(latestVersion, currentVersion) <= 0) {
        outputChannel.appendLine('[Update] Already on latest version');
        return;
    }

    // Check if user skipped this version
    const skippedVersion = context.globalState.get<string>(SKIPPED_VERSION_KEY);
    if (skippedVersion === latestVersion) {
        outputChannel.appendLine('[Update] User skipped this version');
        return;
    }

    // Show update notification
    const selection = await vscode.window.showInformationMessage(
        `Flutter Skill ${latestVersion} is available (current: ${currentVersion})`,
        'Update Now',
        'View Changes',
        'Skip This Version'
    );

    if (selection === 'Update Now') {
        // Open VSCode extension marketplace
        vscode.env.openExternal(
            vscode.Uri.parse('vscode:extension/ai-dashboad.flutter-skill')
        );
    } else if (selection === 'View Changes') {
        vscode.env.openExternal(
            vscode.Uri.parse(`https://github.com/ai-dashboad/flutter-skill/releases/tag/v${latestVersion}`)
        );
    } else if (selection === 'Skip This Version') {
        await context.globalState.update(SKIPPED_VERSION_KEY, latestVersion);
    }
}
