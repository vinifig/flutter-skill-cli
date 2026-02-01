package com.aidashboad.flutterskill.ui

import com.aidashboad.flutterskill.Session
import com.aidashboad.flutterskill.SessionManager
import com.aidashboad.flutterskill.SessionState
import com.intellij.openapi.project.Project
import com.intellij.ui.JBColor
import com.intellij.util.ui.JBUI
import java.awt.Component
import java.awt.Cursor
import java.awt.FlowLayout
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import javax.swing.*

/**
 * Session tabs for managing multiple Flutter app connections
 *
 * Displays tabs for each session with:
 * - Session name and device
 * - Status indicators (● ○ ⏳ ⚠️)
 * - Click to switch session
 * - Close button on each tab
 * - "+" button to create new session
 */
class SessionTabBar(private val project: Project) : JPanel() {
    private val sessionManager = SessionManager.getInstance(project)
    private val tabComponents = mutableMapOf<String, JComponent>()

    /**
     * Listener for session activation
     */
    var onSessionActivated: ((Session) -> Unit)? = null

    /**
     * Listener for session close
     */
    var onSessionClosed: ((Session) -> Unit)? = null

    /**
     * Listener for new session request
     */
    var onNewSessionRequested: (() -> Unit)? = null

    init {
        layout = FlowLayout(FlowLayout.LEFT, JBUI.scale(4), JBUI.scale(4))
        border = BorderFactory.createCompoundBorder(
            BorderFactory.createMatteBorder(0, 0, 1, 0, FlutterSkillColors.border),
            JBUI.Borders.empty(8, 12)
        )
        background = FlutterSkillColors.bg1

        // Listen to session changes
        setupListeners()

        // Build initial UI
        refresh()
    }

    /**
     * Setup listeners for session manager events
     */
    private fun setupListeners() {
        // Listen for state changes (to update tab status)
        sessionManager.addStateChangeListener { session ->
            updateTabForSession(session)
        }

        // Listen for session list changes (add/remove)
        sessionManager.addSessionListListener {
            refresh()
        }
    }

    /**
     * Refresh all tabs
     */
    fun refresh() {
        removeAll()
        tabComponents.clear()

        val sessions = sessionManager.getAllSessions()
        val activeSession = sessionManager.getActiveSession()

        // Create tab for each session
        for (session in sessions) {
            val tab = createSessionTab(session, session == activeSession)
            tabComponents[session.id] = tab
            add(tab)
        }

        // Add "new session" button
        add(createNewSessionButton())

        revalidate()
        repaint()
    }

    /**
     * Update tab for a specific session
     */
    private fun updateTabForSession(session: Session) {
        val tab = tabComponents[session.id] ?: return
        val index = components.indexOf(tab)
        if (index >= 0) {
            val activeSession = sessionManager.getActiveSession()
            val newTab = createSessionTab(session, session == activeSession)
            remove(index)
            add(newTab, index)
            tabComponents[session.id] = newTab
            revalidate()
            repaint()
        }
    }

    /**
     * Create a session tab component
     */
    private fun createSessionTab(session: Session, isActive: Boolean): JComponent {
        val panel = JPanel()
        panel.layout = BoxLayout(panel, BoxLayout.X_AXIS)
        panel.border = BorderFactory.createCompoundBorder(
            if (isActive) {
                BorderFactory.createLineBorder(FlutterSkillColors.primary, 2, true)
            } else {
                BorderFactory.createLineBorder(FlutterSkillColors.border, 1, true)
            },
            JBUI.Borders.empty(4, 8)
        )

        // Background color
        panel.background = if (isActive) {
            FlutterSkillColors.bg2
        } else {
            FlutterSkillColors.bg1
        }

        // Status indicator
        val statusLabel = JLabel(getStatusIcon(session.state))
        statusLabel.foreground = getStatusColor(session.state)
        statusLabel.font = statusLabel.font.deriveFont(14f)

        // Session name label
        val nameText = if (session.deviceId.isNotEmpty()) {
            "${session.name} (${session.deviceId})"
        } else {
            session.name
        }
        val nameLabel = JLabel(nameText)
        nameLabel.font = nameLabel.font.deriveFont(11f)
        nameLabel.foreground = if (isActive) {
            FlutterSkillColors.text
        } else {
            FlutterSkillColors.textSecondary
        }

        // Close button
        val closeBtn = JButton("✕")
        closeBtn.font = closeBtn.font.deriveFont(10f)
        closeBtn.isOpaque = false
        closeBtn.isBorderPainted = false
        closeBtn.isContentAreaFilled = false
        closeBtn.cursor = Cursor.getPredefinedCursor(Cursor.HAND_CURSOR)
        closeBtn.toolTipText = "Close session"
        closeBtn.foreground = FlutterSkillColors.textSecondary
        closeBtn.addActionListener {
            onSessionClosed?.invoke(session)
        }

        // Hover effect on close button
        closeBtn.addMouseListener(object : MouseAdapter() {
            override fun mouseEntered(e: MouseEvent) {
                closeBtn.foreground = FlutterSkillColors.error
            }

            override fun mouseExited(e: MouseEvent) {
                closeBtn.foreground = FlutterSkillColors.textSecondary
            }
        })

        // Make panel clickable to activate session
        panel.cursor = Cursor.getPredefinedCursor(Cursor.HAND_CURSOR)
        panel.addMouseListener(object : MouseAdapter() {
            override fun mouseClicked(e: MouseEvent) {
                // Don't activate if clicking close button
                if (SwingUtilities.isDescendingFrom(e.component, closeBtn)) {
                    return
                }
                activateSession(session)
            }

            override fun mouseEntered(e: MouseEvent) {
                if (!isActive) {
                    panel.background = FlutterSkillColors.hoverBackground
                }
            }

            override fun mouseExited(e: MouseEvent) {
                if (!isActive) {
                    panel.background = FlutterSkillColors.bg1
                }
            }
        })

        // Layout components
        panel.add(statusLabel)
        panel.add(Box.createHorizontalStrut(JBUI.scale(4)))
        panel.add(nameLabel)
        panel.add(Box.createHorizontalStrut(JBUI.scale(8)))
        panel.add(closeBtn)

        return panel
    }

    /**
     * Create the "+" button for adding new sessions
     */
    private fun createNewSessionButton(): JComponent {
        val button = JButton("+")
        button.font = button.font.deriveFont(14f).deriveFont(java.awt.Font.BOLD)
        button.toolTipText = "Create new session"
        button.cursor = Cursor.getPredefinedCursor(Cursor.HAND_CURSOR)
        button.border = BorderFactory.createCompoundBorder(
            BorderFactory.createLineBorder(FlutterSkillColors.border, 1, true),
            JBUI.Borders.empty(4, 12)
        )
        button.isOpaque = false
        button.isContentAreaFilled = false

        button.addActionListener {
            onNewSessionRequested?.invoke()
        }

        // Hover effect
        button.addMouseListener(object : MouseAdapter() {
            override fun mouseEntered(e: MouseEvent) {
                button.isContentAreaFilled = true
                button.background = FlutterSkillColors.hoverBackground
            }

            override fun mouseExited(e: MouseEvent) {
                button.isContentAreaFilled = false
            }
        })

        return button
    }

    /**
     * Activate a session
     */
    private fun activateSession(session: Session) {
        if (sessionManager.switchToSession(session.id)) {
            refresh()
            onSessionActivated?.invoke(session)
        }
    }

    /**
     * Get status icon for session state
     */
    private fun getStatusIcon(state: SessionState): String {
        return when (state) {
            SessionState.CONNECTED -> "●"      // Filled circle
            SessionState.DISCONNECTED -> "○"   // Empty circle
            SessionState.LAUNCHING -> "⏳"     // Hourglass
            SessionState.ERROR -> "⚠️"         // Warning
            SessionState.CREATED -> "○"        // Empty circle
        }
    }

    /**
     * Get status color for session state
     */
    private fun getStatusColor(state: SessionState): java.awt.Color {
        return when (state) {
            SessionState.CONNECTED -> FlutterSkillColors.connected
            SessionState.DISCONNECTED -> FlutterSkillColors.disconnected
            SessionState.LAUNCHING -> FlutterSkillColors.connecting
            SessionState.ERROR -> FlutterSkillColors.errorStatus
            SessionState.CREATED -> FlutterSkillColors.disconnected
        }
    }
}
