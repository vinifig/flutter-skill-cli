import * as vscode from 'vscode';
import { ConnectionState, VmServiceInfo } from './vmServiceScanner';

export class StatusBar {
    private statusBarItem: vscode.StatusBarItem;
    private currentState: ConnectionState = 'disconnected';

    constructor() {
        this.statusBarItem = vscode.window.createStatusBarItem(
            vscode.StatusBarAlignment.Left,
            100
        );
        this.statusBarItem.command = 'flutter-skill.showStatus';
        this.update('disconnected');
        this.statusBarItem.show();
    }

    /**
     * Update the status bar with the current connection state
     */
    update(state: ConnectionState, service?: VmServiceInfo): void {
        this.currentState = state;

        switch (state) {
            case 'disconnected':
                this.statusBarItem.text = '$(debug-disconnect) Flutter Skill';
                this.statusBarItem.tooltip = 'No Flutter app connected. Click for options.';
                this.statusBarItem.backgroundColor = undefined;
                break;

            case 'connecting':
                this.statusBarItem.text = '$(sync~spin) Flutter Skill';
                this.statusBarItem.tooltip = 'Connecting to Flutter app...';
                this.statusBarItem.backgroundColor = undefined;
                break;

            case 'connected':
                this.statusBarItem.text = '$(check) Flutter Skill';
                this.statusBarItem.tooltip = service
                    ? `Connected to Flutter app on port ${service.port}`
                    : 'Connected to Flutter app';
                this.statusBarItem.backgroundColor = undefined;
                break;

            case 'error':
                this.statusBarItem.text = '$(error) Flutter Skill';
                this.statusBarItem.tooltip = 'Connection error. Click for options.';
                this.statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
                break;
        }
    }

    /**
     * Get the current state
     */
    getState(): ConnectionState {
        return this.currentState;
    }

    /**
     * Show the status bar item
     */
    show(): void {
        this.statusBarItem.show();
    }

    /**
     * Hide the status bar item
     */
    hide(): void {
        this.statusBarItem.hide();
    }

    /**
     * Dispose of the status bar item
     */
    dispose(): void {
        this.statusBarItem.dispose();
    }
}

/**
 * Show status menu with options based on current state
 */
export async function showStatusMenu(
    state: ConnectionState,
    commands: {
        launch: () => Promise<void>;
        inspect: () => Promise<void>;
        rescan: () => Promise<void>;
        configureAgents: () => Promise<void>;
    }
): Promise<void> {
    interface StatusQuickPickItem extends vscode.QuickPickItem {
        action?: () => Promise<void>;
    }

    const items: StatusQuickPickItem[] = [];

    if (state === 'disconnected' || state === 'error') {
        items.push({
            label: '$(rocket) Launch Flutter App',
            description: 'Start a Flutter app with Flutter Skill',
            action: commands.launch
        });
        items.push({
            label: '$(search) Scan for Running Apps',
            description: 'Scan ports for running Flutter apps',
            action: commands.rescan
        });
    }

    if (state === 'connected') {
        items.push({
            label: '$(list-tree) Inspect UI',
            description: 'View the widget tree of the running app',
            action: commands.inspect
        });
    }

    items.push({
        label: '$(settings-gear) Configure AI Agents',
        description: 'Set up MCP integration for Claude Code, Cursor, Windsurf',
        action: commands.configureAgents
    });

    const selected = await vscode.window.showQuickPick(items, {
        placeHolder: 'Flutter Skill Options'
    });

    if (selected?.action) {
        await selected.action();
    }
}
