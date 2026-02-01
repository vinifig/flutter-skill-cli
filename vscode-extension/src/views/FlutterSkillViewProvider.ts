/**
 * WebviewViewProvider for Flutter Skill sidebar
 */

import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import { VmServiceScanner, VmServiceInfo, ConnectionState } from '../vmServiceScanner';
import { ActivityTracker } from '../state/ActivityTracker';
import { UIElement, EditorStatus, ExtensionState, ActivityItem } from '../state/ExtensionState';
import { detectAiAgents, checkExistingConfigs } from '../mcpConfigManager';

export class FlutterSkillViewProvider implements vscode.WebviewViewProvider {
    private _view?: vscode.WebviewView;
    private activityTracker: ActivityTracker;
    private elements: UIElement[] = [];
    private aiEditors: EditorStatus[] = [];

    constructor(
        private readonly extensionUri: vscode.Uri,
        private readonly outputChannel: vscode.OutputChannel,
        private readonly vmScanner: VmServiceScanner
    ) {
        this.activityTracker = new ActivityTracker();

        // Setup activity tracker listener
        this.activityTracker.onChange((history) => {
            this.postMessage({ command: 'updateActivity', data: history });
        });

        // Detect AI editors on startup
        this.updateAiEditors();
    }

    /**
     * Called when the view is first displayed
     */
    resolveWebviewView(
        webviewView: vscode.WebviewView,
        context: vscode.WebviewViewResolveContext,
        _token: vscode.CancellationToken
    ): void {
        this._view = webviewView;

        // Configure webview options
        webviewView.webview.options = {
            enableScripts: true,
            localResourceRoots: [this.extensionUri]
        };

        // Load HTML content
        webviewView.webview.html = this.getHtmlContent(webviewView.webview);

        // Handle messages from webview
        webviewView.webview.onDidReceiveMessage(
            async (message) => await this.handleMessage(message)
        );

        // Send initial state
        this.sendFullState();
    }

    /**
     * Update connection status
     */
    updateConnectionStatus(state: ConnectionState, service?: VmServiceInfo): void {
        const connectionData = {
            status: state,
            service,
            device: service ? this.getDeviceInfo(service) : undefined
        };

        this.postMessage({
            command: 'updateStatus',
            data: connectionData
        });

        // Log connection changes to activity
        if (state === 'connected' && service) {
            this.activityTracker.addActivity(
                'other',
                `Connected to ${this.getDeviceInfo(service)}`,
                true
            );
        } else if (state === 'disconnected') {
            this.activityTracker.addActivity(
                'other',
                'Disconnected from app',
                true
            );
        }
    }

    /**
     * Update interactive elements list
     */
    updateInteractiveElements(elements: UIElement[]): void {
        this.elements = elements;
        this.postMessage({
            command: 'updateElements',
            data: elements
        });
    }

    /**
     * Add an activity item
     */
    addActivityItem(
        type: ActivityItem['type'],
        description: string,
        success: boolean = true,
        details?: string
    ): void {
        this.activityTracker.addActivity(type, description, success, details);
    }

    /**
     * Update AI editors status
     */
    updateAiEditors(): void {
        const detectedAgents = detectAiAgents();
        const configuredAgents = checkExistingConfigs();

        this.aiEditors = detectedAgents.map(agent => ({
            name: agent.name,
            displayName: agent.displayName,
            detected: agent.detected,
            configured: configuredAgents.some(c => c.name === agent.name)
        }));

        this.postMessage({
            command: 'updateAiEditors',
            data: this.aiEditors
        });
    }

    /**
     * Handle messages from webview
     */
    private async handleMessage(message: any): Promise<void> {
        switch (message.command) {
            case 'launchApp':
                await vscode.commands.executeCommand('flutter-skill.launch');
                this.addActivityItem('launch', 'Launching Flutter app');
                break;

            case 'inspect':
                await this.handleInspect();
                break;

            case 'screenshot':
                await vscode.commands.executeCommand('flutter-skill.screenshot');
                this.addActivityItem('screenshot', 'Taking screenshot');
                break;

            case 'hotReload':
                await this.handleHotReload();
                break;

            case 'disconnect':
                this.vmScanner.disconnect();
                this.addActivityItem('other', 'Disconnected from app');
                break;

            case 'refresh':
                await this.vmScanner.rescan();
                this.addActivityItem('other', 'Refreshing connection');
                break;

            case 'tap':
                await this.handleTap(message.key);
                break;

            case 'inspectElement':
                this.addActivityItem('inspect', `Inspecting element: ${message.key}`);
                vscode.window.showInformationMessage(`Inspecting: ${message.key}`);
                break;

            case 'showInputDialog':
                await this.handleInputDialog(message.key);
                break;

            case 'clearField':
                this.addActivityItem('input', `Clearing field: ${message.key}`);
                vscode.window.showInformationMessage(`Clearing field: ${message.key}`);
                break;

            case 'viewHistory':
                await this.showHistoryPanel();
                break;

            case 'configureEditor':
                await vscode.commands.executeCommand('flutter-skill.configureAgents');
                this.updateAiEditors();
                break;

            case 'openSettings':
                await vscode.commands.executeCommand('workbench.action.openSettings', 'flutter-skill');
                break;

            case 'openHelp':
                await vscode.env.openExternal(
                    vscode.Uri.parse('https://github.com/ai-dashboad/flutter-skill')
                );
                break;

            case 'clearHistory':
                this.activityTracker.clearHistory();
                break;

            case 'requestFullState':
                this.sendFullState();
                break;
        }
    }

    /**
     * Handle inspect action - get UI elements
     */
    private async handleInspect(): Promise<void> {
        const service = this.vmScanner.getCurrentService();
        if (!service) {
            vscode.window.showErrorMessage('No Flutter app connected');
            return;
        }

        try {
            this.addActivityItem('inspect', 'Inspecting UI elements...');

            // Get interactive elements from VM service
            const elements = await this.vmScanner.getInteractiveElements();

            if (elements.length > 0) {
                this.updateInteractiveElements(elements);
                this.addActivityItem('inspect', `Found ${elements.length} interactive elements`, true);
                vscode.window.showInformationMessage(`Found ${elements.length} interactive elements`);
            } else {
                this.addActivityItem('inspect', 'No interactive elements found', true);
                vscode.window.showInformationMessage('No interactive elements found');
            }
        } catch (error) {
            vscode.window.showErrorMessage(`Failed to inspect: ${error}`);
            this.addActivityItem('inspect', 'Failed to inspect UI', false, String(error));
        }
    }

    /**
     * Handle tap action
     */
    private async handleTap(key: string): Promise<void> {
        const service = this.vmScanner.getCurrentService();
        if (!service) {
            vscode.window.showErrorMessage('No Flutter app connected');
            this.addActivityItem('tap', `Failed to tap ${key}: No connection`, false);
            return;
        }

        try {
            await this.vmScanner.performTap(key);
            this.addActivityItem('tap', `Tapped element: ${key}`, true);
            vscode.window.showInformationMessage(`Tapped: ${key}`);
        } catch (error) {
            vscode.window.showErrorMessage(`Failed to tap: ${error}`);
            this.addActivityItem('tap', `Failed to tap ${key}`, false, String(error));
        }
    }

    /**
     * Handle hot reload
     */
    private async handleHotReload(): Promise<void> {
        const service = this.vmScanner.getCurrentService();
        if (!service) {
            vscode.window.showErrorMessage('No Flutter app connected');
            return;
        }

        try {
            this.addActivityItem('hotReload', 'Triggering hot reload...');
            await this.vmScanner.performHotReload();
            this.addActivityItem('hotReload', 'Hot reload completed', true);
            vscode.window.showInformationMessage('Hot reload successful');
        } catch (error) {
            vscode.window.showErrorMessage(`Failed to hot reload: ${error}`);
            this.addActivityItem('hotReload', 'Hot reload failed', false, String(error));
        }
    }

    /**
     * Handle input dialog
     */
    private async handleInputDialog(key: string): Promise<void> {
        const service = this.vmScanner.getCurrentService();
        if (!service) {
            vscode.window.showErrorMessage('No Flutter app connected');
            return;
        }

        const text = await vscode.window.showInputBox({
            prompt: `Enter text for ${key}`,
            placeHolder: 'Text to enter'
        });

        if (text !== undefined && text !== '') {
            try {
                await this.vmScanner.performEnterText(key, text);
                this.addActivityItem('input', `Entered text in ${key}: "${text}"`, true);
                vscode.window.showInformationMessage(`Text entered in ${key}`);
            } catch (error) {
                vscode.window.showErrorMessage(`Failed to enter text: ${error}`);
                this.addActivityItem('input', `Failed to enter text in ${key}`, false, String(error));
            }
        }
    }

    /**
     * Show history panel
     */
    private async showHistoryPanel(): Promise<void> {
        const history = this.activityTracker.getHistory();
        const items = history.map(item => ({
            label: `${this.getActivityIcon(item.type)} ${item.description}`,
            description: ActivityTracker.formatTimestamp(item.timestamp),
            detail: item.details
        }));

        await vscode.window.showQuickPick(items, {
            title: 'Activity History',
            placeHolder: 'Recent actions'
        });
    }

    /**
     * Get icon for activity type
     */
    private getActivityIcon(type: string): string {
        const icons: Record<string, string> = {
            tap: '👆',
            input: '⌨️',
            screenshot: '📸',
            inspect: '🔍',
            launch: '▶️',
            hotReload: '🔄',
            other: '•'
        };
        return icons[type] || '•';
    }

    /**
     * Send full state to webview
     */
    private sendFullState(): void {
        const service = this.vmScanner.getCurrentService();
        const state: ExtensionState = {
            connection: {
                status: service ? 'connected' : 'disconnected',
                service,
                device: service ? this.getDeviceInfo(service) : undefined
            },
            elements: this.elements,
            activityHistory: this.activityTracker.getHistory(),
            aiEditors: this.aiEditors
        };

        this.postMessage({
            command: 'fullState',
            data: state
        });
    }

    /**
     * Post message to webview
     */
    private postMessage(message: any): void {
        if (this._view) {
            this._view.webview.postMessage(message);
        }
    }

    /**
     * Get device info from service
     */
    private getDeviceInfo(service: VmServiceInfo): string {
        if (service.appName) {
            return service.appName;
        }
        return `Port ${service.port}`;
    }

    /**
     * Get HTML content for webview
     */
    private getHtmlContent(webview: vscode.Webview): string {
        const htmlPath = path.join(
            this.extensionUri.fsPath,
            'src',
            'views',
            'improved-sidebar.html'
        );

        let html = fs.readFileSync(htmlPath, 'utf-8');

        // Replace CSP placeholder if needed
        const nonce = this.getNonce();
        html = html.replace(
            /<head>/,
            `<head>\n<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource} 'unsafe-inline'; script-src 'nonce-${nonce}';">`
        );

        // Add nonce to script tag
        html = html.replace(/<script>/g, `<script nonce="${nonce}">`);

        return html;
    }

    /**
     * Generate nonce for CSP
     */
    private getNonce(): string {
        let text = '';
        const possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
        for (let i = 0; i < 32; i++) {
            text += possible.charAt(Math.floor(Math.random() * possible.length));
        }
        return text;
    }
}
