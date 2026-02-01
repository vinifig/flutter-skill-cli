package com.aidashboad.flutterskill.model

/**
 * Represents a UI element from the Flutter app
 */
data class UIElement(
    val key: String,
    val type: String,
    val text: String? = null,
    val hint: String? = null,
    val value: String? = null,
    val position: Position? = null,
    val size: Size? = null,
    val enabled: Boolean = true,
    val visible: Boolean = true
) {
    data class Position(val x: Int, val y: Int)
    data class Size(val width: Int, val height: Int)

    /**
     * Get a human-readable description of the element
     */
    fun getDescription(): String {
        val parts = mutableListOf<String>()
        text?.let { parts.add("Text: \"$it\"") }
        hint?.let { parts.add("Hint: \"$it\"") }
        value?.let { parts.add("Value: \"$it\"") }
        position?.let { parts.add("Position: (${it.x}, ${it.y})") }
        size?.let { parts.add("Size: ${it.width}×${it.height}") }
        return parts.joinToString(" • ")
    }

    /**
     * Get an icon for the element type
     */
    fun getIcon(): String {
        return when {
            type.contains("Button", ignoreCase = true) -> "🔘"
            type.contains("TextField", ignoreCase = true) -> "📝"
            type.contains("Input", ignoreCase = true) -> "📝"
            type.contains("Text", ignoreCase = true) -> "📄"
            type.contains("Icon", ignoreCase = true) -> "🎨"
            type.contains("Image", ignoreCase = true) -> "🖼️"
            else -> "📱"
        }
    }

    /**
     * Check if this is an input element
     */
    fun isInputElement(): Boolean {
        return type.contains("TextField", ignoreCase = true) ||
                type.contains("Input", ignoreCase = true)
    }
}
