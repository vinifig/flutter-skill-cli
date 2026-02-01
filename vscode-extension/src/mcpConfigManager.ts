import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import * as child_process from 'child_process';

export interface AgentConfig {
    name: string;
    displayName: string;
    configPath: string;
    detected: boolean;
}

export interface McpServerConfig {
    command: string;
    args: string[];
}

export interface McpConfig {
    mcpServers?: {
        [key: string]: McpServerConfig;
    };
    [key: string]: unknown;
}

const FLUTTER_SKILL_MCP_CONFIG: McpServerConfig = {
    command: 'flutter-skill',
    args: ['server']
};

/**
 * Detects which AI agents are installed on the system
 */
export function detectAiAgents(): AgentConfig[] {
    const homeDir = os.homedir();
    const agents: AgentConfig[] = [];

    // Claude Code - check for ~/.claude/ directory or claude command
    // Claude Code uses ~/.claude/settings.json for MCP config
    const claudeDir = path.join(homeDir, '.claude');
    const claudeConfigPath = path.join(claudeDir, 'settings.json');
    const claudeDetected = fs.existsSync(claudeDir) || isCommandAvailable('claude');
    agents.push({
        name: 'claude-code',
        displayName: 'Claude Code',
        configPath: claudeConfigPath,
        detected: claudeDetected
    });

    // Also check for project-level .mcp.json for Claude Code
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (workspaceFolder) {
        const projectMcpPath = path.join(workspaceFolder.uri.fsPath, '.mcp.json');
        agents.push({
            name: 'claude-code-project',
            displayName: 'Claude Code (Project)',
            configPath: projectMcpPath,
            detected: fs.existsSync(projectMcpPath) || claudeDetected
        });
    }

    // Cursor - check for ~/.cursor/ directory
    const cursorDir = path.join(homeDir, '.cursor');
    const cursorConfigPath = path.join(cursorDir, 'mcp.json');
    agents.push({
        name: 'cursor',
        displayName: 'Cursor',
        configPath: cursorConfigPath,
        detected: fs.existsSync(cursorDir)
    });

    // Windsurf - check for ~/.codeium/windsurf/ directory
    const windsurfDir = path.join(homeDir, '.codeium', 'windsurf');
    const windsurfConfigPath = path.join(windsurfDir, 'mcp_config.json');
    agents.push({
        name: 'windsurf',
        displayName: 'Windsurf',
        configPath: windsurfConfigPath,
        detected: fs.existsSync(windsurfDir)
    });

    return agents;
}

/**
 * Check if a command is available in PATH
 */
function isCommandAvailable(command: string): boolean {
    try {
        const result = child_process.spawnSync(
            process.platform === 'win32' ? 'where' : 'which',
            [command],
            { stdio: 'pipe' }
        );
        return result.status === 0;
    } catch {
        return false;
    }
}

/**
 * Creates a backup of the config file
 */
function backupConfig(configPath: string): string | null {
    if (!fs.existsSync(configPath)) {
        return null;
    }

    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const backupPath = `${configPath}.backup-${timestamp}`;
    fs.copyFileSync(configPath, backupPath);
    return backupPath;
}

/**
 * Merges flutter-skill MCP config into existing config non-destructively
 */
export function mergeMcpConfig(configPath: string): { success: boolean; backupPath?: string; error?: string } {
    try {
        // Ensure parent directory exists
        const configDir = path.dirname(configPath);
        if (!fs.existsSync(configDir)) {
            fs.mkdirSync(configDir, { recursive: true });
        }

        let existingConfig: McpConfig = {};
        let backupPath: string | null = null;

        // Read existing config if it exists
        if (fs.existsSync(configPath)) {
            backupPath = backupConfig(configPath);
            const content = fs.readFileSync(configPath, 'utf-8');
            try {
                existingConfig = JSON.parse(content);
            } catch {
                return { success: false, error: 'Invalid JSON in existing config file' };
            }
        }

        // Check if flutter-skill is already configured
        if (existingConfig.mcpServers?.['flutter-skill']) {
            return { success: true, backupPath: backupPath || undefined };
        }

        // Merge the config
        if (!existingConfig.mcpServers) {
            existingConfig.mcpServers = {};
        }
        existingConfig.mcpServers['flutter-skill'] = FLUTTER_SKILL_MCP_CONFIG;

        // Write back with pretty JSON
        fs.writeFileSync(configPath, JSON.stringify(existingConfig, null, 2) + '\n', 'utf-8');

        return { success: true, backupPath: backupPath || undefined };
    } catch (error) {
        return { success: false, error: error instanceof Error ? error.message : 'Unknown error' };
    }
}

/**
 * Configure a single agent
 */
export function configureAgent(agent: AgentConfig): { success: boolean; backupPath?: string; error?: string } {
    return mergeMcpConfig(agent.configPath);
}

/**
 * Main orchestration function - prompts user and configures all detected agents
 */
export async function configureAllAgents(outputChannel: vscode.OutputChannel): Promise<void> {
    const agents = detectAiAgents();
    const detectedAgents = agents.filter(a => a.detected);

    if (detectedAgents.length === 0) {
        vscode.window.showInformationMessage(
            'No AI agents detected. Install Claude Code, Cursor, or Windsurf to use Flutter Skill MCP integration.'
        );
        return;
    }

    // Build list of agents to show
    const agentNames = detectedAgents.map(a => a.displayName).join(', ');
    const message = `Flutter Skill detected these AI agents: ${agentNames}. Configure MCP integration?`;

    const selection = await vscode.window.showInformationMessage(
        message,
        'Configure All',
        'Choose Agents',
        'Skip'
    );

    if (selection === 'Skip' || !selection) {
        return;
    }

    let agentsToConfig = detectedAgents;

    if (selection === 'Choose Agents') {
        const items = detectedAgents.map(a => ({
            label: a.displayName,
            description: a.configPath,
            picked: true,
            agent: a
        }));

        const selected = await vscode.window.showQuickPick(items, {
            canPickMany: true,
            placeHolder: 'Select agents to configure'
        });

        if (!selected || selected.length === 0) {
            return;
        }

        agentsToConfig = selected.map(s => s.agent);
    }

    // Configure each selected agent
    const results: { agent: AgentConfig; result: { success: boolean; backupPath?: string; error?: string } }[] = [];

    for (const agent of agentsToConfig) {
        const result = configureAgent(agent);
        results.push({ agent, result });
        outputChannel.appendLine(`[Config] ${agent.displayName}: ${result.success ? 'success' : result.error}`);
        if (result.backupPath) {
            outputChannel.appendLine(`[Config] Backup created: ${result.backupPath}`);
        }
    }

    // Show summary
    const successCount = results.filter(r => r.result.success).length;
    const failCount = results.filter(r => !r.result.success).length;

    if (failCount === 0) {
        vscode.window.showInformationMessage(
            `Flutter Skill MCP configured for ${successCount} agent(s). Restart your AI agents to use the tools.`
        );
    } else {
        const failedAgents = results
            .filter(r => !r.result.success)
            .map(r => r.agent.displayName)
            .join(', ');
        vscode.window.showWarningMessage(
            `Configured ${successCount} agent(s). Failed: ${failedAgents}. Check output for details.`
        );
        outputChannel.show();
    }
}

/**
 * Check if any agent already has flutter-skill configured
 */
export function checkExistingConfigs(): AgentConfig[] {
    const agents = detectAiAgents();
    const configured: AgentConfig[] = [];

    for (const agent of agents) {
        if (fs.existsSync(agent.configPath)) {
            try {
                const content = fs.readFileSync(agent.configPath, 'utf-8');
                const config: McpConfig = JSON.parse(content);
                if (config.mcpServers?.['flutter-skill']) {
                    configured.push(agent);
                }
            } catch {
                // Ignore parse errors
            }
        }
    }

    return configured;
}
