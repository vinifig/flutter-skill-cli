package com.aidashboad.flutterskill.ui

import com.intellij.openapi.project.Project
import com.intellij.util.ui.JBUI
import java.awt.Component
import javax.swing.*

/**
 * Base class for card-based UI components
 */
abstract class CardComponent(protected val project: Project) {
    protected val panel: JPanel = JPanel()

    val component: JComponent
        get() = panel

    init {
        setupPanel()
        buildContent()
    }

    /**
     * Setup the panel with card-like styling
     */
    private fun setupPanel() {
        panel.layout = BoxLayout(panel, BoxLayout.Y_AXIS)
        panel.alignmentX = Component.LEFT_ALIGNMENT
        panel.border = BorderFactory.createCompoundBorder(
            BorderFactory.createLineBorder(FlutterSkillColors.border, 1, true),
            JBUI.Borders.empty(12)
        )
        panel.background = FlutterSkillColors.bg2
    }

    /**
     * Build the card content
     * Override this in subclasses
     */
    protected abstract fun buildContent()

    /**
     * Add a section title to the card
     */
    protected fun addTitle(title: String, icon: String? = null) {
        val titleLabel = JLabel(if (icon != null) "$icon $title" else title)
        titleLabel.font = titleLabel.font.deriveFont(12f).deriveFont(java.awt.Font.BOLD)
        titleLabel.foreground = FlutterSkillColors.text
        titleLabel.alignmentX = Component.LEFT_ALIGNMENT
        panel.add(titleLabel)
        panel.add(Box.createVerticalStrut(JBUI.scale(8)))
    }

    /**
     * Add a horizontal separator
     */
    protected fun addSeparator() {
        val separator = JSeparator(JSeparator.HORIZONTAL)
        separator.alignmentX = Component.LEFT_ALIGNMENT
        separator.maximumSize = java.awt.Dimension(Integer.MAX_VALUE, 1)
        panel.add(Box.createVerticalStrut(JBUI.scale(8)))
        panel.add(separator)
        panel.add(Box.createVerticalStrut(JBUI.scale(8)))
    }

    /**
     * Create a styled button
     */
    protected fun createButton(
        text: String,
        tooltip: String? = null,
        action: () -> Unit
    ): JButton {
        return JButton(text).apply {
            tooltip?.let { toolTipText = it }
            addActionListener { action() }
            alignmentX = Component.LEFT_ALIGNMENT
        }
    }

    /**
     * Create a status badge label
     */
    protected fun createStatusBadge(
        text: String,
        color: java.awt.Color
    ): JLabel {
        return JLabel("● $text").apply {
            foreground = color
            font = font.deriveFont(11f).deriveFont(java.awt.Font.BOLD)
            alignmentX = Component.LEFT_ALIGNMENT
        }
    }

    /**
     * Create an info row (icon + text)
     */
    protected fun createInfoRow(icon: String, text: String): JPanel {
        val row = JPanel()
        row.layout = BoxLayout(row, BoxLayout.X_AXIS)
        row.alignmentX = Component.LEFT_ALIGNMENT
        row.isOpaque = false

        val iconLabel = JLabel(icon)
        iconLabel.font = iconLabel.font.deriveFont(12f)

        val textLabel = JLabel(text)
        textLabel.font = textLabel.font.deriveFont(11f)
        textLabel.foreground = FlutterSkillColors.textSecondary

        row.add(iconLabel)
        row.add(Box.createHorizontalStrut(JBUI.scale(6)))
        row.add(textLabel)
        row.add(Box.createHorizontalGlue())

        return row
    }

    /**
     * Refresh the card content
     */
    open fun refresh() {
        panel.removeAll()
        buildContent()
        panel.revalidate()
        panel.repaint()
    }
}
