package com.aidashboad.flutterskill.model

import java.util.UUID

/**
 * Represents an activity history entry
 */
data class ActivityEntry(
    val id: String = UUID.randomUUID().toString(),
    val type: ActivityType,
    val description: String,
    val timestamp: Long = System.currentTimeMillis(),
    val success: Boolean = true,
    val details: String? = null
) {
    enum class ActivityType {
        TAP,
        INPUT,
        SCREENSHOT,
        INSPECT,
        LAUNCH,
        HOT_RELOAD,
        OTHER;

        fun getIcon(): String {
            return when (this) {
                TAP -> "👆"
                INPUT -> "⌨️"
                SCREENSHOT -> "📸"
                INSPECT -> "🔍"
                LAUNCH -> "▶️"
                HOT_RELOAD -> "🔄"
                OTHER -> "•"
            }
        }
    }

    /**
     * Format timestamp as relative time
     */
    fun getRelativeTime(): String {
        val now = System.currentTimeMillis()
        val diff = now - timestamp
        val seconds = diff / 1000
        val minutes = seconds / 60
        val hours = minutes / 60
        val days = hours / 24

        return when {
            days > 0 -> "$days day${if (days > 1) "s" else ""} ago"
            hours > 0 -> "$hours hour${if (hours > 1) "s" else ""} ago"
            minutes > 0 -> "$minutes minute${if (minutes > 1) "s" else ""} ago"
            else -> "just now"
        }
    }
}
