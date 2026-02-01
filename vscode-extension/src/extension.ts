import * as vscode from 'vscode';
import * as child_process from 'child_process';
import * as path from 'path';
import * as fs from 'fs';
import { configureAllAgents, detectAiAgents, checkExistingConfigs } from './mcpConfigManager';
import { VmServiceScanner } from './vmServiceScanner';
import { StatusBar, showStatusMenu } from './statusBar';
import { promptSetupFlutterSkill, setupFlutterSkill, hasFlutterSkillDependency } from './flutterSetup';
import { ensureNativeBinary, getBestBinaryPath } from './nativeBinary';
import { checkForUpdates } from './updateChecker';
import { FlutterSkillViewProvider } from './views/FlutterSkillViewProvider';

// Read version from package.json dynamically
function getExtensionVersion(): string {
    try {
        const packageJsonPath = path.join(__dirname, '..', 'package.json');
        const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8'));
        return packageJson.version;
    } catch (error) {
        console.error('Failed to read version from package.json:', error);
        return '0.0.0'; // Fallback version
    }
}

const EXTENSION_VERSION = getExtensionVersion();

let mcpServerProcess: child_process.ChildProcess | undefined;
let outputChannel: vscode.OutputChannel;
let statusBar: StatusBar;
let vmScanner: VmServiceScanner;
let viewProvider: FlutterSkillViewProvider;

export function activate(context: vscode.ExtensionContext) {
    outputChannel = vscode.window.createOutputChannel('Flutter Skill');
    statusBar = new StatusBar();
    vmScanner = new VmServiceScanner(outputChannel);

    // Create webview view provider
    viewProvider = new FlutterSkillViewProvider(
        context.extensionUri,
        outputChannel,
        vmScanner
    );

    // Register webview view provider
    context.subscriptions.push(
        vscode.window.registerWebviewViewProvider(
            'flutterSkillView',
            viewProvider,
            { webviewOptions: { retainContextWhenHidden: true } }
        )
    );

    // Connect scanner state changes to status bar and webview
    vmScanner.onStateChange((state, service) => {
        statusBar.update(state, service);
        viewProvider.updateConnectionStatus(state, service);
    });

    // Register commands
    context.subscriptions.push(
        vscode.commands.registerCommand('flutter-skill.launch', launchApp),
        vscode.commands.registerCommand('flutter-skill.inspect', inspectUI),
        vscode.commands.registerCommand('flutter-skill.screenshot', takeScreenshot),
        vscode.commands.registerCommand('flutter-skill.startMcpServer', startMcpServer),
        vscode.commands.registerCommand('flutter-skill.stopMcpServer', stopMcpServer),
        vscode.commands.registerCommand('flutter-skill.configureAgents', () => configureAllAgents(outputChannel)),
        vscode.commands.registerCommand('flutter-skill.rescan', () => vmScanner.rescan()),
        vscode.commands.registerCommand('flutter-skill.showStatus', showStatus),
        vscode.commands.registerCommand('flutter-skill.setupDependency', () => setupFlutterSkillCommand())
    );

    // Add status bar and scanner to subscriptions for cleanup
    context.subscriptions.push(statusBar);
    context.subscriptions.push({ dispose: () => vmScanner.stop() });

    // Check if this is a Flutter project
    const isFlutterProject = checkIsFlutterProject();

    if (isFlutterProject) {
        outputChannel.appendLine('Flutter project detected');

        // Auto-initialization based on settings
        const config = vscode.workspace.getConfiguration('flutter-skill');

        // Auto-start MCP server if configured
        if (config.get('autoStartMcpServer')) {
            startMcpServer();
        }

        // Start VM service scanning if configured
        if (config.get('scanVmServicePorts')) {
            vmScanner.start();
        }

        // Prompt to configure AI agents if configured and not already done
        if (config.get('autoConfigureAgents')) {
            promptConfigureAgentsIfNeeded();
        }

        // Auto-setup flutter_skill dependency if configured
        if (config.get('autoSetupDependency')) {
            promptSetupFlutterSkill(outputChannel);
        }

        // Download native binary in background for faster MCP startup
        ensureNativeBinary(EXTENSION_VERSION, outputChannel);
    }

    // Check for updates (once per 24 hours)
    checkForUpdates(EXTENSION_VERSION, context, outputChannel);

    outputChannel.appendLine('Flutter Skill extension activated');
}

export function deactivate() {
    if (mcpServerProcess) {
        mcpServerProcess.kill();
    }
    vmScanner?.stop();
}

/**
 * Check if the current workspace is a Flutter project
 */
function checkIsFlutterProject(): boolean {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        return false;
    }

    const pubspecPath = path.join(workspaceFolder.uri.fsPath, 'pubspec.yaml');
    if (!fs.existsSync(pubspecPath)) {
        return false;
    }

    // Check if pubspec contains flutter dependency
    try {
        const content = fs.readFileSync(pubspecPath, 'utf-8');
        return content.includes('flutter:') || content.includes('flutter_test:');
    } catch {
        return false;
    }
}

/**
 * Prompt to configure AI agents if not already configured
 */
async function promptConfigureAgentsIfNeeded(): Promise<void> {
    // Check if any agents are detected but not configured
    const agents = detectAiAgents();
    const detectedAgents = agents.filter(a => a.detected);
    const configuredAgents = checkExistingConfigs();

    // If no agents detected or all are configured, skip
    if (detectedAgents.length === 0) {
        return;
    }

    // Check if flutter-skill is already configured for any detected agent
    const unconfiguredAgents = detectedAgents.filter(
        detected => !configuredAgents.some(configured => configured.name === detected.name)
    );

    if (unconfiguredAgents.length === 0) {
        outputChannel.appendLine('All detected AI agents already have flutter-skill configured');
        return;
    }

    // Show notification with option to configure
    const agentNames = unconfiguredAgents.map(a => a.displayName).join(', ');
    const message = `Configure Flutter Skill MCP for ${agentNames}?`;

    const selection = await vscode.window.showInformationMessage(
        message,
        'Configure',
        'Later',
        "Don't Ask Again"
    );

    if (selection === 'Configure') {
        await configureAllAgents(outputChannel);
    } else if (selection === "Don't Ask Again") {
        const config = vscode.workspace.getConfiguration('flutter-skill');
        await config.update('autoConfigureAgents', false, vscode.ConfigurationTarget.Global);
    }
}

/**
 * Show status menu
 */
async function showStatus(): Promise<void> {
    const state = statusBar.getState();
    await showStatusMenu(state, {
        launch: launchApp,
        inspect: inspectUI,
        rescan: async () => { await vmScanner.rescan(); },
        configureAgents: () => configureAllAgents(outputChannel)
    });
}

async function launchApp(): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    const config = vscode.workspace.getConfiguration('flutter-skill');
    const dartPath = config.get<string>('dartPath') || 'dart';

    // Check for pubspec.yaml
    const pubspecPath = path.join(workspaceFolder.uri.fsPath, 'pubspec.yaml');
    if (!fs.existsSync(pubspecPath)) {
        vscode.window.showErrorMessage('No pubspec.yaml found. Is this a Flutter project?');
        return;
    }

    // Run flutter_skill launch
    const terminal = vscode.window.createTerminal('Flutter Skill');
    terminal.show();
    terminal.sendText(`${dartPath} pub global run flutter_skill launch .`);

    vscode.window.showInformationMessage('Launching Flutter app with Flutter Skill...');
}

async function inspectUI(): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    const config = vscode.workspace.getConfiguration('flutter-skill');
    const dartPath = config.get<string>('dartPath') || 'dart';

    // Check for .flutter_skill_uri
    const uriFile = path.join(workspaceFolder.uri.fsPath, '.flutter_skill_uri');
    if (!fs.existsSync(uriFile)) {
        vscode.window.showErrorMessage('No running Flutter app found. Launch an app first.');
        return;
    }

    // Run inspect command
    const terminal = vscode.window.createTerminal('Flutter Skill Inspect');
    terminal.show();
    terminal.sendText(`${dartPath} pub global run flutter_skill inspect`);
}

async function takeScreenshot(): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    const config = vscode.workspace.getConfiguration('flutter-skill');
    const dartPath = config.get<string>('dartPath') || 'dart';

    // Check for .flutter_skill_uri
    const uriFile = path.join(workspaceFolder.uri.fsPath, '.flutter_skill_uri');
    if (!fs.existsSync(uriFile)) {
        vscode.window.showErrorMessage('No running Flutter app found. Launch an app first.');
        return;
    }

    // Get save location
    const saveUri = await vscode.window.showSaveDialog({
        defaultUri: vscode.Uri.file(path.join(workspaceFolder.uri.fsPath, 'screenshot.png')),
        filters: { 'Images': ['png'] }
    });

    if (!saveUri) return;

    // Run screenshot command
    const terminal = vscode.window.createTerminal('Flutter Skill Screenshot');
    terminal.show();
    terminal.sendText(`${dartPath} pub global run flutter_skill screenshot "${saveUri.fsPath}"`);

    vscode.window.showInformationMessage(`Screenshot will be saved to ${saveUri.fsPath}`);
}

async function startMcpServer(): Promise<void> {
    if (mcpServerProcess) {
        vscode.window.showInformationMessage('MCP Server is already running');
        return;
    }

    // Get the best available binary (native or dart fallback)
    const { path: binaryPath, isNative } = await getBestBinaryPath(EXTENSION_VERSION, outputChannel);

    if (isNative) {
        outputChannel.appendLine(`[MCP] Using native binary: ${binaryPath}`);
        mcpServerProcess = child_process.spawn(binaryPath, ['server'], {
            stdio: ['pipe', 'pipe', 'pipe']
        });
    } else {
        outputChannel.appendLine('[MCP] Using Dart runtime (native binary not available)');
        const config = vscode.workspace.getConfiguration('flutter-skill');
        const dartPath = config.get<string>('dartPath') || 'dart';
        mcpServerProcess = child_process.spawn(dartPath, ['pub', 'global', 'run', 'flutter_skill', 'server'], {
            stdio: ['pipe', 'pipe', 'pipe']
        });
    }

    mcpServerProcess.stdout?.on('data', (data) => {
        outputChannel.appendLine(`[MCP] ${data}`);
    });

    mcpServerProcess.stderr?.on('data', (data) => {
        outputChannel.appendLine(`[MCP Error] ${data}`);
    });

    mcpServerProcess.on('close', (code) => {
        outputChannel.appendLine(`MCP Server exited with code ${code}`);
        mcpServerProcess = undefined;
    });

    outputChannel.appendLine('Flutter Skill MCP Server started');
}

async function stopMcpServer(): Promise<void> {
    if (!mcpServerProcess) {
        vscode.window.showInformationMessage('MCP Server is not running');
        return;
    }

    mcpServerProcess.kill();
    mcpServerProcess = undefined;
    vscode.window.showInformationMessage('MCP Server stopped');
}

async function setupFlutterSkillCommand(): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    if (hasFlutterSkillDependency(workspaceFolder.uri.fsPath)) {
        vscode.window.showInformationMessage('flutter_skill is already configured in this project');
        return;
    }

    await setupFlutterSkill(workspaceFolder.uri.fsPath, outputChannel);
}
