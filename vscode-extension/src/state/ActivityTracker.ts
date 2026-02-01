/**
 * Activity history tracker for Flutter Skill
 */

import { ActivityItem } from './ExtensionState';

export class ActivityTracker {
    private history: ActivityItem[] = [];
    private maxHistorySize = 20;
    private onChangeCallbacks: ((history: ActivityItem[]) => void)[] = [];

    /**
     * Add a new activity item
     */
    addActivity(
        type: ActivityItem['type'],
        description: string,
        success: boolean = true,
        details?: string
    ): void {
        const item: ActivityItem = {
            id: `${Date.now()}-${Math.random().toString(36).substring(7)}`,
            type,
            description,
            timestamp: Date.now(),
            success,
            details
        };

        // Add to beginning of array (most recent first)
        this.history.unshift(item);

        // Limit history size
        if (this.history.length > this.maxHistorySize) {
            this.history = this.history.slice(0, this.maxHistorySize);
        }

        // Notify listeners
        this.notifyChange();
    }

    /**
     * Get all history items
     */
    getHistory(): ActivityItem[] {
        return [...this.history];
    }

    /**
     * Clear all history
     */
    clearHistory(): void {
        this.history = [];
        this.notifyChange();
    }

    /**
     * Register a callback for history changes
     */
    onChange(callback: (history: ActivityItem[]) => void): void {
        this.onChangeCallbacks.push(callback);
    }

    /**
     * Notify all listeners of history change
     */
    private notifyChange(): void {
        const history = this.getHistory();
        for (const callback of this.onChangeCallbacks) {
            callback(history);
        }
    }

    /**
     * Format timestamp as relative time
     */
    static formatTimestamp(timestamp: number): string {
        const now = Date.now();
        const diff = now - timestamp;

        const seconds = Math.floor(diff / 1000);
        const minutes = Math.floor(seconds / 60);
        const hours = Math.floor(minutes / 60);
        const days = Math.floor(hours / 24);

        if (days > 0) {
            return `${days} day${days > 1 ? 's' : ''} ago`;
        }
        if (hours > 0) {
            return `${hours} hour${hours > 1 ? 's' : ''} ago`;
        }
        if (minutes > 0) {
            return `${minutes} minute${minutes > 1 ? 's' : ''} ago`;
        }
        return 'just now';
    }
}
