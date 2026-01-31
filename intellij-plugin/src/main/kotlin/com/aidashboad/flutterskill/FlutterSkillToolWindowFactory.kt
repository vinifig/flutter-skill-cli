package com.aidashboad.flutterskill

import com.intellij.openapi.project.Project
import com.intellij.openapi.wm.ToolWindow
import com.intellij.openapi.wm.ToolWindowFactory
import com.intellij.ui.content.ContentFactory
import com.intellij.ui.components.JBScrollPane
import com.intellij.util.ui.JBUI
import javax.swing.*
import java.awt.*

class FlutterSkillToolWindowFactory : ToolWindowFactory {
    override fun createToolWindowContent(project: Project, toolWindow: ToolWindow) {
        val panel = FlutterSkillPanel(project)
        val content = ContentFactory.getInstance().createContent(panel, "", false)
        toolWindow.contentManager.addContent(content)
    }

    override fun shouldBeAvailable(project: Project): Boolean = true
}

class FlutterSkillPanel(private val project: Project) : JPanel(BorderLayout()) {
    private val aiToolsPanel: JPanel
    private val statusLabel: JLabel

    init {
        border = JBUI.Borders.empty(8)

        // ===== Top Toolbar =====
        val toolbar = JPanel(FlowLayout(FlowLayout.LEFT, 8, 4))
        toolbar.border = JBUI.Borders.emptyBottom(8)

        val launchBtn = createButton("Launch App", "Start Flutter app with Flutter Skill") {
            FlutterSkillService.getInstance(project).launchApp()
        }
        val inspectBtn = createButton("Inspect", "Inspect UI elements") {
            FlutterSkillService.getInstance(project).inspect()
        }
        val screenshotBtn = createButton("Screenshot", "Take app screenshot") {
            FlutterSkillService.getInstance(project).screenshot()
        }
        val mcpBtn = createButton("Start MCP", "Start MCP server for AI agents") {
            FlutterSkillService.getInstance(project).startMcpServer()
        }

        toolbar.add(launchBtn)
        toolbar.add(inspectBtn)
        toolbar.add(screenshotBtn)
        toolbar.add(mcpBtn)

        add(toolbar, BorderLayout.NORTH)

        // ===== Main Content Area =====
        val mainPanel = JPanel()
        mainPanel.layout = BoxLayout(mainPanel, BoxLayout.Y_AXIS)
        mainPanel.border = JBUI.Borders.empty(4)

        // Status Section
        val statusPanel = createSection("Connection Status")
        statusLabel = JLabel("Not connected")
        statusLabel.icon = UIManager.getIcon("OptionPane.informationIcon")
        statusPanel.add(statusLabel)
        mainPanel.add(statusPanel)
        mainPanel.add(Box.createVerticalStrut(12))

        // AI Tools Section
        val aiToolsSection = createSection("Detected AI Tools")
        aiToolsPanel = JPanel()
        aiToolsPanel.layout = BoxLayout(aiToolsPanel, BoxLayout.Y_AXIS)
        aiToolsPanel.alignmentX = Component.LEFT_ALIGNMENT
        aiToolsSection.add(aiToolsPanel)

        val refreshBtn = JButton("Refresh")
        refreshBtn.addActionListener { refreshAiTools() }
        aiToolsSection.add(Box.createVerticalStrut(8))
        aiToolsSection.add(refreshBtn)

        mainPanel.add(aiToolsSection)
        mainPanel.add(Box.createVerticalStrut(12))

        // MCP Config Section
        val mcpSection = createSection("MCP Configuration")
        val mcpConfigText = """
            Add to your AI agent's MCP config:

            {
              "mcpServers": {
                "flutter-skill": {
                  "command": "flutter-skill",
                  "args": ["server"]
                }
              }
            }
        """.trimIndent()

        val mcpTextArea = JTextArea(mcpConfigText)
        mcpTextArea.isEditable = false
        mcpTextArea.font = Font(Font.MONOSPACED, Font.PLAIN, 11)
        mcpTextArea.background = UIManager.getColor("TextField.background")
        mcpTextArea.border = JBUI.Borders.empty(8)
        mcpSection.add(mcpTextArea)

        val copyBtn = JButton("Copy Config")
        copyBtn.addActionListener {
            val clipboard = Toolkit.getDefaultToolkit().systemClipboard
            val selection = java.awt.datatransfer.StringSelection("""
{
  "mcpServers": {
    "flutter-skill": {
      "command": "flutter-skill",
      "args": ["server"]
    }
  }
}
            """.trimIndent())
            clipboard.setContents(selection, selection)
        }
        mcpSection.add(Box.createVerticalStrut(8))
        mcpSection.add(copyBtn)

        mainPanel.add(mcpSection)
        mainPanel.add(Box.createVerticalGlue())

        val scrollPane = JBScrollPane(mainPanel)
        scrollPane.border = null
        add(scrollPane, BorderLayout.CENTER)

        // Initial load
        refreshAiTools()
    }

    private fun createButton(text: String, tooltip: String, action: () -> Unit): JButton {
        return JButton(text).apply {
            toolTipText = tooltip
            addActionListener { action() }
        }
    }

    private fun createSection(title: String): JPanel {
        val panel = JPanel()
        panel.layout = BoxLayout(panel, BoxLayout.Y_AXIS)
        panel.alignmentX = Component.LEFT_ALIGNMENT
        panel.border = BorderFactory.createCompoundBorder(
            BorderFactory.createTitledBorder(title),
            JBUI.Borders.empty(8)
        )
        return panel
    }

    private fun refreshAiTools() {
        aiToolsPanel.removeAll()

        SwingUtilities.invokeLater {
            Thread {
                val tools = AiToolDetector.getInstance().detectTools(forceRefresh = true)
                val installedTools = tools.filter { it.installed }
                val notInstalledTools = tools.filter { !it.installed }

                SwingUtilities.invokeLater {
                    if (installedTools.isEmpty()) {
                        aiToolsPanel.add(JLabel("No AI tools detected"))
                    } else {
                        // Installed tools
                        for (tool in installedTools) {
                            val toolPanel = createToolRow(tool, true)
                            aiToolsPanel.add(toolPanel)
                            aiToolsPanel.add(Box.createVerticalStrut(4))
                        }

                        // Separator
                        if (notInstalledTools.isNotEmpty()) {
                            aiToolsPanel.add(Box.createVerticalStrut(8))
                            aiToolsPanel.add(JSeparator())
                            aiToolsPanel.add(Box.createVerticalStrut(4))
                            aiToolsPanel.add(JLabel("Not installed:").apply {
                                foreground = Color.GRAY
                            })
                            aiToolsPanel.add(Box.createVerticalStrut(4))

                            for (tool in notInstalledTools.take(5)) {
                                val toolPanel = createToolRow(tool, false)
                                aiToolsPanel.add(toolPanel)
                                aiToolsPanel.add(Box.createVerticalStrut(2))
                            }
                        }
                    }

                    aiToolsPanel.revalidate()
                    aiToolsPanel.repaint()
                }
            }.start()
        }
    }

    private fun createToolRow(tool: AiToolDetector.AiTool, installed: Boolean): JPanel {
        val row = JPanel(BorderLayout())
        row.alignmentX = Component.LEFT_ALIGNMENT
        row.maximumSize = Dimension(Integer.MAX_VALUE, 28)

        val icon = if (installed) "✓" else "○"
        val color = if (installed) Color(0, 150, 0) else Color.GRAY

        val nameLabel = JLabel("$icon ${tool.name}")
        nameLabel.foreground = color
        nameLabel.toolTipText = "${tool.description}\nCommand: ${tool.command}"

        row.add(nameLabel, BorderLayout.WEST)

        if (installed && tool.configPath != null) {
            val configBtn = JButton("Configure")
            configBtn.font = configBtn.font.deriveFont(10f)
            configBtn.preferredSize = Dimension(70, 20)
            configBtn.addActionListener {
                configureMcp(tool)
            }
            row.add(configBtn, BorderLayout.EAST)
        }

        if (installed && tool.version != null) {
            val versionLabel = JLabel(tool.version)
            versionLabel.foreground = Color.GRAY
            versionLabel.font = versionLabel.font.deriveFont(10f)
            row.add(versionLabel, BorderLayout.CENTER)
        }

        return row
    }

    private fun configureMcp(tool: AiToolDetector.AiTool) {
        val configPath = tool.configPath ?: return
        McpConfigManager.getInstance().configureForTool(tool.name, configPath)
    }

    fun updateStatus(connected: Boolean, appInfo: String?) {
        statusLabel.text = if (connected) {
            "Connected: ${appInfo ?: "Flutter App"}"
        } else {
            "Not connected"
        }
        statusLabel.icon = if (connected) {
            UIManager.getIcon("OptionPane.informationIcon")
        } else {
            UIManager.getIcon("OptionPane.warningIcon")
        }
    }
}
