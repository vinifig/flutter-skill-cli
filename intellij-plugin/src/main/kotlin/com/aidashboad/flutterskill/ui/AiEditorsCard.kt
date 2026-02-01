package com.aidashboad.flutterskill.ui

import com.aidashboad.flutterskill.AiToolDetector
import com.aidashboad.flutterskill.McpConfigManager
import com.intellij.openapi.project.Project
import com.intellij.util.ui.JBUI
import java.awt.BorderLayout
import java.awt.Component
import java.awt.Dimension
import javax.swing.*

/**
 * Card showing AI editor detection and configuration status
 */
class AiEditorsCard(project: Project) : CardComponent(project) {
    private val tools = mutableListOf<AiToolDetector.AiTool>()

    override fun buildContent() {
        addTitle("AI Editors", "🤖")

        // Detect tools
        val detectedTools = AiToolDetector.getInstance().detectTools()
        tools.clear()
        tools.addAll(detectedTools)

        val installedTools = tools.filter { it.installed }
        val notInstalledTools = tools.filter { !it.installed }.take(3) // Show only top 3

        if (installedTools.isEmpty() && notInstalledTools.isEmpty()) {
            // Empty state
            showEmptyState()
        } else {
            // Show installed tools
            if (installedTools.isNotEmpty()) {
                for (tool in installedTools) {
                    val toolRow = createToolRow(tool, true)
                    panel.add(toolRow)
                    panel.add(Box.createVerticalStrut(JBUI.scale(6)))
                }
            }

            // Show not installed tools (muted)
            if (notInstalledTools.isNotEmpty()) {
                if (installedTools.isNotEmpty()) {
                    addSeparator()
                }

                val notInstalledLabel = JLabel("Not installed:")
                notInstalledLabel.foreground = FlutterSkillColors.textSecondary
                notInstalledLabel.font = notInstalledLabel.font.deriveFont(10f)
                notInstalledLabel.alignmentX = Component.LEFT_ALIGNMENT
                panel.add(notInstalledLabel)
                panel.add(Box.createVerticalStrut(JBUI.scale(4)))

                for (tool in notInstalledTools) {
                    val toolRow = createToolRow(tool, false)
                    panel.add(toolRow)
                    panel.add(Box.createVerticalStrut(JBUI.scale(4)))
                }
            }

            // Refresh button
            panel.add(Box.createVerticalStrut(JBUI.scale(8)))
            val refreshBtn = createButton("Refresh") {
                refreshTools()
            }
            panel.add(refreshBtn)
        }
    }

    /**
     * Show empty state when no tools detected
     */
    private fun showEmptyState() {
        val emptyPanel = JPanel()
        emptyPanel.layout = BoxLayout(emptyPanel, BoxLayout.Y_AXIS)
        emptyPanel.alignmentX = Component.LEFT_ALIGNMENT
        emptyPanel.isOpaque = false

        val iconLabel = JLabel("🤖")
        iconLabel.font = iconLabel.font.deriveFont(48f)
        iconLabel.foreground = FlutterSkillColors.textSecondary
        iconLabel.alignmentX = Component.CENTER_ALIGNMENT

        val textLabel = JLabel("No AI editors detected")
        textLabel.foreground = FlutterSkillColors.textSecondary
        textLabel.font = textLabel.font.deriveFont(12f)
        textLabel.alignmentX = Component.CENTER_ALIGNMENT

        emptyPanel.add(Box.createVerticalStrut(JBUI.scale(16)))
        emptyPanel.add(iconLabel)
        emptyPanel.add(Box.createVerticalStrut(JBUI.scale(8)))
        emptyPanel.add(textLabel)
        emptyPanel.add(Box.createVerticalStrut(JBUI.scale(16)))

        panel.add(emptyPanel)
    }

    /**
     * Create a row for an AI tool
     */
    private fun createToolRow(tool: AiToolDetector.AiTool, installed: Boolean): JPanel {
        val row = JPanel(BorderLayout())
        row.alignmentX = Component.LEFT_ALIGNMENT
        row.maximumSize = Dimension(Integer.MAX_VALUE, JBUI.scale(32))
        row.isOpaque = false

        // Icon + Name
        val leftPanel = JPanel()
        leftPanel.layout = BoxLayout(leftPanel, BoxLayout.X_AXIS)
        leftPanel.isOpaque = false

        val icon = if (installed) "✅" else "○"
        val color = if (installed) FlutterSkillColors.success else FlutterSkillColors.textSecondary

        val nameLabel = JLabel("$icon ${tool.name}")
        nameLabel.foreground = color
        nameLabel.font = nameLabel.font.deriveFont(11f)
        nameLabel.toolTipText = "${tool.description}\nCommand: ${tool.command}"

        leftPanel.add(nameLabel)

        // Version (if available)
        if (installed && tool.version != null) {
            leftPanel.add(Box.createHorizontalStrut(JBUI.scale(8)))
            val versionLabel = JLabel(tool.version)
            versionLabel.foreground = FlutterSkillColors.textSecondary
            versionLabel.font = versionLabel.font.deriveFont(9f)
            leftPanel.add(versionLabel)
        }

        row.add(leftPanel, BorderLayout.WEST)

        // Configure button (if installed and has config path)
        if (installed && tool.configPath != null) {
            val configBtn = JButton("Configure")
            configBtn.font = configBtn.font.deriveFont(10f)
            configBtn.preferredSize = Dimension(JBUI.scale(80), JBUI.scale(24))
            configBtn.addActionListener {
                configureTool(tool)
            }
            row.add(configBtn, BorderLayout.EAST)
        }

        return row
    }

    /**
     * Configure MCP for a tool
     */
    private fun configureTool(tool: AiToolDetector.AiTool) {
        val configPath = tool.configPath ?: return
        McpConfigManager.getInstance().configureForTool(tool.name, configPath)

        JOptionPane.showMessageDialog(
            panel,
            "MCP configured for ${tool.name}!\nRestart ${tool.name} to use Flutter Skill.",
            "Configuration Complete",
            JOptionPane.INFORMATION_MESSAGE
        )

        refreshTools()
    }

    /**
     * Refresh tools detection
     */
    private fun refreshTools() {
        SwingUtilities.invokeLater {
            Thread {
                AiToolDetector.getInstance().detectTools(forceRefresh = true)
                SwingUtilities.invokeLater {
                    refresh()
                }
            }.start()
        }
    }
}
