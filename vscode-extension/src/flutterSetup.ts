import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import * as child_process from 'child_process';

/**
 * Check if flutter_skill is in the project's pubspec.yaml
 */
export function hasFlutterSkillDependency(workspacePath: string): boolean {
    const pubspecPath = path.join(workspacePath, 'pubspec.yaml');
    if (!fs.existsSync(pubspecPath)) {
        return false;
    }

    try {
        const content = fs.readFileSync(pubspecPath, 'utf-8');
        return content.includes('flutter_skill:');
    } catch {
        return false;
    }
}

/**
 * Check if FlutterSkillBinding is initialized in main.dart
 */
export function hasFlutterSkillBinding(workspacePath: string): boolean {
    const mainDartPath = path.join(workspacePath, 'lib', 'main.dart');
    if (!fs.existsSync(mainDartPath)) {
        return false;
    }

    try {
        const content = fs.readFileSync(mainDartPath, 'utf-8');
        return content.includes('FlutterSkillBinding.ensureInitialized()');
    } catch {
        return false;
    }
}

/**
 * Add flutter_skill dependency to pubspec.yaml
 */
export function addFlutterSkillDependency(workspacePath: string): { success: boolean; error?: string } {
    const pubspecPath = path.join(workspacePath, 'pubspec.yaml');

    try {
        let content = fs.readFileSync(pubspecPath, 'utf-8');

        // Find the dependencies section and add flutter_skill
        const dependenciesMatch = content.match(/^dependencies:\s*\n/m);
        if (dependenciesMatch) {
            const insertPos = dependenciesMatch.index! + dependenciesMatch[0].length;
            const before = content.slice(0, insertPos);
            const after = content.slice(insertPos);
            content = before + '  flutter_skill: ^0.2.6\n' + after;
        } else {
            // No dependencies section, add one
            content += '\ndependencies:\n  flutter_skill: ^0.2.6\n';
        }

        fs.writeFileSync(pubspecPath, content, 'utf-8');
        return { success: true };
    } catch (error) {
        return { success: false, error: error instanceof Error ? error.message : 'Unknown error' };
    }
}

/**
 * Add FlutterSkillBinding initialization to main.dart
 */
export function addFlutterSkillBinding(workspacePath: string): { success: boolean; error?: string } {
    const mainDartPath = path.join(workspacePath, 'lib', 'main.dart');

    try {
        let content = fs.readFileSync(mainDartPath, 'utf-8');

        // Add import if not present
        if (!content.includes("import 'package:flutter_skill/flutter_skill.dart'")) {
            // Find the last import line
            const importMatch = content.match(/^import .+;$/gm);
            if (importMatch) {
                const lastImport = importMatch[importMatch.length - 1];
                const lastImportIndex = content.lastIndexOf(lastImport) + lastImport.length;
                content = content.slice(0, lastImportIndex) +
                    "\nimport 'package:flutter_skill/flutter_skill.dart';" +
                    content.slice(lastImportIndex);
            } else {
                // No imports found, add at the beginning
                content = "import 'package:flutter_skill/flutter_skill.dart';\n" + content;
            }
        }

        // Add FlutterSkillBinding.ensureInitialized() to main()
        if (!content.includes('FlutterSkillBinding.ensureInitialized()')) {
            // Find main() function and add initialization
            const mainMatch = content.match(/void\s+main\s*\(\s*\)\s*(async\s*)?\{/);
            if (mainMatch) {
                const insertPos = mainMatch.index! + mainMatch[0].length;
                const before = content.slice(0, insertPos);
                const after = content.slice(insertPos);
                content = before + '\n  FlutterSkillBinding.ensureInitialized();' + after;
            }
        }

        fs.writeFileSync(mainDartPath, content, 'utf-8');
        return { success: true };
    } catch (error) {
        return { success: false, error: error instanceof Error ? error.message : 'Unknown error' };
    }
}

/**
 * Run flutter pub get
 */
export async function runFlutterPubGet(workspacePath: string, outputChannel: vscode.OutputChannel): Promise<boolean> {
    return new Promise((resolve) => {
        const config = vscode.workspace.getConfiguration('flutter-skill');
        const flutterPath = config.get<string>('flutterPath') || 'flutter';

        outputChannel.appendLine(`Running ${flutterPath} pub get...`);

        const process = child_process.spawn(flutterPath, ['pub', 'get'], {
            cwd: workspacePath,
            stdio: ['ignore', 'pipe', 'pipe']
        });

        process.stdout?.on('data', (data) => {
            outputChannel.append(data.toString());
        });

        process.stderr?.on('data', (data) => {
            outputChannel.append(data.toString());
        });

        process.on('close', (code) => {
            if (code === 0) {
                outputChannel.appendLine('flutter pub get completed successfully');
                resolve(true);
            } else {
                outputChannel.appendLine(`flutter pub get failed with code ${code}`);
                resolve(false);
            }
        });

        process.on('error', (err) => {
            outputChannel.appendLine(`Error running flutter pub get: ${err.message}`);
            resolve(false);
        });
    });
}

/**
 * Check and prompt to setup flutter_skill in the Flutter project
 */
export async function promptSetupFlutterSkill(outputChannel: vscode.OutputChannel): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        return;
    }

    const workspacePath = workspaceFolder.uri.fsPath;

    // Check if already setup
    const hasDependency = hasFlutterSkillDependency(workspacePath);
    const hasBinding = hasFlutterSkillBinding(workspacePath);

    if (hasDependency && hasBinding) {
        outputChannel.appendLine('flutter_skill is already configured in this project');
        return;
    }

    // Prompt user
    const message = !hasDependency
        ? 'Add flutter_skill to this project for AI-powered app control?'
        : 'Initialize FlutterSkillBinding in main.dart?';

    const selection = await vscode.window.showInformationMessage(
        message,
        'Setup',
        'Later',
        "Don't Ask Again"
    );

    if (selection === 'Setup') {
        await setupFlutterSkill(workspacePath, outputChannel);
    } else if (selection === "Don't Ask Again") {
        const config = vscode.workspace.getConfiguration('flutter-skill');
        await config.update('autoSetupDependency', false, vscode.ConfigurationTarget.Global);
    }
}

/**
 * Setup flutter_skill in the Flutter project
 */
export async function setupFlutterSkill(workspacePath: string, outputChannel: vscode.OutputChannel): Promise<boolean> {
    outputChannel.show();
    outputChannel.appendLine('Setting up flutter_skill...');

    // Add dependency if needed
    if (!hasFlutterSkillDependency(workspacePath)) {
        outputChannel.appendLine('Adding flutter_skill dependency to pubspec.yaml...');
        const depResult = addFlutterSkillDependency(workspacePath);
        if (!depResult.success) {
            vscode.window.showErrorMessage(`Failed to add dependency: ${depResult.error}`);
            return false;
        }
        outputChannel.appendLine('Added flutter_skill dependency');
    }

    // Run flutter pub get
    const pubGetSuccess = await runFlutterPubGet(workspacePath, outputChannel);
    if (!pubGetSuccess) {
        vscode.window.showErrorMessage('Failed to run flutter pub get');
        return false;
    }

    // Add binding if needed
    if (!hasFlutterSkillBinding(workspacePath)) {
        outputChannel.appendLine('Adding FlutterSkillBinding to main.dart...');
        const bindResult = addFlutterSkillBinding(workspacePath);
        if (!bindResult.success) {
            vscode.window.showErrorMessage(`Failed to add binding: ${bindResult.error}`);
            return false;
        }
        outputChannel.appendLine('Added FlutterSkillBinding initialization');
    }

    vscode.window.showInformationMessage(
        'flutter_skill configured! Restart your Flutter app to enable AI control.',
        'OK'
    );

    return true;
}
