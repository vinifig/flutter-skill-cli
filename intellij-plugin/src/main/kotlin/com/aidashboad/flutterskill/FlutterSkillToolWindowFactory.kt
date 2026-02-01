package com.aidashboad.flutterskill

import com.aidashboad.flutterskill.ui.*
import com.intellij.openapi.project.Project
import com.intellij.openapi.wm.ToolWindow
import com.intellij.openapi.wm.ToolWindowFactory
import com.intellij.ui.content.ContentFactory
import com.intellij.ui.components.JBScrollPane
import com.intellij.util.ui.JBUI
import java.awt.BorderLayout
import java.awt.Dimension
import javax.swing.Box
import javax.swing.BoxLayout
import javax.swing.JPanel

class FlutterSkillToolWindowFactory : ToolWindowFactory {
    override fun createToolWindowContent(project: Project, toolWindow: ToolWindow) {
        val panel = FlutterSkillPanel(project)
        val content = ContentFactory.getInstance().createContent(panel, "", false)
        toolWindow.contentManager.addContent(content)

        // Set default width
        toolWindow.component.preferredSize = Dimension(350, -1)
    }

    override fun shouldBeAvailable(project: Project): Boolean = true
}

/**
 * Main panel for Flutter Skill tool window with card-based UI
 */
class FlutterSkillPanel(private val project: Project) : JPanel(BorderLayout()) {
    private val connectionCard: ConnectionStatusCard
    private val quickActionsCard: QuickActionsCard
    private val elementsCard: InteractiveElementsCard
    private val activityCard: RecentActivityCard
    private val aiEditorsCard: AiEditorsCard

    init {
        border = JBUI.Borders.empty(12)

        // Create main panel with vertical layout
        val mainPanel = JPanel()
        mainPanel.layout = BoxLayout(mainPanel, BoxLayout.Y_AXIS)
        mainPanel.border = JBUI.Borders.empty(4)

        // Initialize all cards
        connectionCard = ConnectionStatusCard(project)
        quickActionsCard = QuickActionsCard(project)
        elementsCard = InteractiveElementsCard(project)
        activityCard = RecentActivityCard(project)
        aiEditorsCard = AiEditorsCard(project)

        // Add cards to main panel with spacing (16px for consistency with VSCode)
        mainPanel.add(connectionCard.component)
        mainPanel.add(Box.createVerticalStrut(JBUI.scale(16)))

        mainPanel.add(quickActionsCard.component)
        mainPanel.add(Box.createVerticalStrut(JBUI.scale(16)))

        mainPanel.add(elementsCard.component)
        mainPanel.add(Box.createVerticalStrut(JBUI.scale(16)))

        mainPanel.add(activityCard.component)
        mainPanel.add(Box.createVerticalStrut(JBUI.scale(16)))

        mainPanel.add(aiEditorsCard.component)
        mainPanel.add(Box.createVerticalGlue())

        // Wrap in scroll pane
        val scrollPane = JBScrollPane(mainPanel)
        scrollPane.border = null
        add(scrollPane, BorderLayout.CENTER)

        // Setup state listeners
        setupStateListeners()
        setupServiceCallbacks()
    }

    /**
     * Setup listeners for VM service scanner state changes
     */
    private fun setupStateListeners() {
        VmServiceScanner.getInstance(project).onStateChange { state, service ->
            // Update connection status card
            connectionCard.updateConnectionState(state, service)

            // Update quick actions button states
            quickActionsCard.updateButtonStates(state)

            // Log activity
            when (state) {
                ConnectionState.CONNECTED -> {
                    activityCard.addActivity(
                        com.aidashboad.flutterskill.model.ActivityEntry(
                            type = com.aidashboad.flutterskill.model.ActivityEntry.ActivityType.OTHER,
                            description = "Connected to ${service?.appName ?: "Flutter app"}",
                            success = true
                        )
                    )
                }
                ConnectionState.DISCONNECTED -> {
                    activityCard.addActivity(
                        com.aidashboad.flutterskill.model.ActivityEntry(
                            type = com.aidashboad.flutterskill.model.ActivityEntry.ActivityType.OTHER,
                            description = "Disconnected from app",
                            success = true
                        )
                    )
                }
                ConnectionState.ERROR -> {
                    activityCard.addActivity(
                        com.aidashboad.flutterskill.model.ActivityEntry(
                            type = com.aidashboad.flutterskill.model.ActivityEntry.ActivityType.OTHER,
                            description = "Connection error",
                            success = false
                        )
                    )
                }
                ConnectionState.CONNECTING -> {
                    // Don't log connecting state
                }
            }
        }
    }

    /**
     * Setup callbacks for FlutterSkillService
     */
    private fun setupServiceCallbacks() {
        val service = FlutterSkillService.getInstance(project)

        // Callback for elements update
        service.onElementsUpdate { elements ->
            elementsCard.updateElements(elements)
        }

        // Callback for activity updates
        service.onActivityAdd { entry ->
            activityCard.addActivity(entry)
        }
    }

    /**
     * Update connection status (called from service)
     */
    fun updateStatus(connected: Boolean, appInfo: String?) {
        // This method is kept for backwards compatibility
        // The new implementation uses state listeners
        val state = if (connected) ConnectionState.CONNECTED else ConnectionState.DISCONNECTED
        val service = if (connected) {
            VmServiceInfo("", 0, appInfo)
        } else {
            null
        }
        connectionCard.updateConnectionState(state, service)
    }
}
