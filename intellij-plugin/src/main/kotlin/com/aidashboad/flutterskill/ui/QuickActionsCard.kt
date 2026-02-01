package com.aidashboad.flutterskill.ui

import com.aidashboad.flutterskill.ConnectionState
import com.aidashboad.flutterskill.FlutterSkillService
import com.aidashboad.flutterskill.VmServiceScanner
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.Messages
import com.intellij.util.ui.JBUI
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.awt.Component
import java.awt.Dimension
import java.awt.GridLayout
import javax.swing.Box
import javax.swing.JButton
import javax.swing.JPanel

/**
 * Card showing quick action buttons in a 2x2 grid
 */
class QuickActionsCard(project: Project) : CardComponent(project) {
    private var isConnected = false
    private val actionButtons = mutableListOf<JButton>()

    override fun buildContent() {
        addTitle("Quick Actions", "⚡")

        // Create 2x2 grid
        val gridPanel = JPanel(GridLayout(2, 2, JBUI.scale(8), JBUI.scale(8)))
        gridPanel.alignmentX = Component.LEFT_ALIGNMENT
        gridPanel.maximumSize = Dimension(Integer.MAX_VALUE, JBUI.scale(100))
        gridPanel.isOpaque = false

        // Create action buttons
        val launchBtn = createActionButton("▶️ Launch App", "Launch Flutter app") {
            FlutterSkillService.getInstance(project).launchApp()
        }

        val inspectBtn = createActionButton("🔍 Inspect", "Inspect UI elements") {
            FlutterSkillService.getInstance(project).inspect()
        }

        val screenshotBtn = createActionButton("📸 Screenshot", "Take screenshot") {
            FlutterSkillService.getInstance(project).screenshot()
        }

        val hotReloadBtn = createActionButton("🔄 Hot Reload", "Hot reload app") {
            performHotReload()
        }

        // Add buttons to grid
        gridPanel.add(launchBtn)
        gridPanel.add(inspectBtn)
        gridPanel.add(screenshotBtn)
        gridPanel.add(hotReloadBtn)

        // Store buttons for state updates
        actionButtons.clear()
        actionButtons.add(inspectBtn)
        actionButtons.add(screenshotBtn)
        actionButtons.add(hotReloadBtn)

        panel.add(gridPanel)

        // Update button states
        updateButtonStates()
    }

    /**
     * Create an action button with consistent styling
     */
    private fun createActionButton(
        text: String,
        tooltip: String,
        action: () -> Unit
    ): JButton {
        return JButton(text).apply {
            toolTipText = tooltip
            preferredSize = Dimension(JBUI.scale(160), JBUI.scale(40))
            addActionListener { action() }
        }
    }

    /**
     * Update button states based on connection
     */
    fun updateButtonStates(state: ConnectionState? = null) {
        val connected = state == ConnectionState.CONNECTED || isConnected
        isConnected = connected

        for (button in actionButtons) {
            button.isEnabled = connected
        }
    }

    /**
     * Perform hot reload on the connected Flutter app
     */
    private fun performHotReload() {
        val scanner = VmServiceScanner.getInstance(project)

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val result = scanner.performHotReload()
                withContext(Dispatchers.Main) {
                    if (result.success) {
                        Messages.showInfoMessage(
                            project,
                            "Hot reload completed successfully",
                            "Hot Reload"
                        )
                    } else {
                        Messages.showErrorDialog(
                            project,
                            "Failed to hot reload: ${result.error?.message}",
                            "Hot Reload Error"
                        )
                    }
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    Messages.showErrorDialog(
                        project,
                        "Error performing hot reload: ${e.message}",
                        "Error"
                    )
                }
            }
        }
    }
}
