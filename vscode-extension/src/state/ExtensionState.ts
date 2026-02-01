/**
 * State management interfaces for Flutter Skill extension
 */

import { VmServiceInfo, ConnectionState } from '../vmServiceScanner';

/**
 * UI Element from Flutter app
 */
export interface UIElement {
    key: string;
    type: string;
    text?: string;
    hint?: string;
    value?: string;
    position?: { x: number; y: number };
    size?: { width: number; height: number };
    enabled?: boolean;
    visible?: boolean;
}

/**
 * Activity history item
 */
export interface ActivityItem {
    id: string;
    type: 'tap' | 'input' | 'screenshot' | 'inspect' | 'launch' | 'hotReload' | 'other';
    description: string;
    timestamp: number;
    success: boolean;
    details?: string;
}

/**
 * AI Editor status
 */
export interface EditorStatus {
    name: string;
    displayName: string;
    detected: boolean;
    configured: boolean;
}

/**
 * Main extension state
 */
export interface ExtensionState {
    connection: {
        status: ConnectionState;
        service?: VmServiceInfo;
        device?: string;
    };
    elements: UIElement[];
    activityHistory: ActivityItem[];
    aiEditors: EditorStatus[];
}
