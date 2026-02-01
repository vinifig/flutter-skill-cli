package com.aidashboad.flutterskill.ui

import com.aidashboad.flutterskill.ConnectionState
import com.aidashboad.flutterskill.VmServiceInfo
import com.aidashboad.flutterskill.VmServiceScanner
import com.intellij.openapi.project.Project
import com.intellij.util.ui.JBUI
import java.awt.Component
import java.awt.FlowLayout
import javax.swing.Box
import javax.swing.BoxLayout
import javax.swing.JButton
import javax.swing.JLabel
import javax.swing.JPanel

/**
 * Card showing connection status and device information
 */
class ConnectionStatusCard(project: Project) : CardComponent(project) {
    private var currentState: ConnectionState = ConnectionState.DISCONNECTED
    private var currentService: VmServiceInfo? = null

    override fun buildContent() {
        addTitle("Connection Status", "🔗")

        // Status badge
        val statusBadge = createStatusBadge(
            getStatusText(currentState),
            getStatusColor(currentState)
        )
        panel.add(statusBadge)
        panel.add(Box.createVerticalStrut(JBUI.scale(8)))

        // Device info (if connected)
        if (currentState == ConnectionState.CONNECTED && currentService != null) {
            val deviceInfo = createInfoRow(
                "📱",
                currentService?.appName ?: "Flutter App"
            )
            panel.add(deviceInfo)
            panel.add(Box.createVerticalStrut(JBUI.scale(4)))

            val portInfo = createInfoRow(
                "⚡",
                "VM Service: :${currentService?.port ?: "N/A"}"
            )
            panel.add(portInfo)
            panel.add(Box.createVerticalStrut(JBUI.scale(12)))

            // Actions for connected state
            val actionsPanel = JPanel(FlowLayout(FlowLayout.LEFT, 8, 0))
            actionsPanel.alignmentX = Component.LEFT_ALIGNMENT
            actionsPanel.isOpaque = false

            val disconnectBtn = createButton("Disconnect") {
                VmServiceScanner.getInstance(project).disconnect()
            }
            val refreshBtn = createButton("🔄 Refresh") {
                VmServiceScanner.getInstance(project).rescan()
            }

            actionsPanel.add(disconnectBtn)
            actionsPanel.add(refreshBtn)
            panel.add(actionsPanel)
        } else {
            // Not connected state
            val infoLabel = JLabel("No Flutter app connected")
            infoLabel.foreground = FlutterSkillColors.textSecondary
            infoLabel.font = infoLabel.font.deriveFont(11f)
            infoLabel.alignmentX = Component.LEFT_ALIGNMENT
            panel.add(infoLabel)
            panel.add(Box.createVerticalStrut(JBUI.scale(12)))

            // Scan action
            val scanBtn = createButton("🔄 Scan for Apps") {
                VmServiceScanner.getInstance(project).rescan()
            }
            panel.add(scanBtn)
        }
    }

    /**
     * Update connection state
     */
    fun updateConnectionState(state: ConnectionState, service: VmServiceInfo?) {
        this.currentState = state
        this.currentService = service
        refresh()
    }

    private fun getStatusText(state: ConnectionState): String {
        return when (state) {
            ConnectionState.CONNECTED -> "Connected"
            ConnectionState.DISCONNECTED -> "Disconnected"
            ConnectionState.CONNECTING -> "Connecting..."
            ConnectionState.ERROR -> "Error"
        }
    }

    private fun getStatusColor(state: ConnectionState): java.awt.Color {
        return when (state) {
            ConnectionState.CONNECTED -> FlutterSkillColors.connected
            ConnectionState.DISCONNECTED -> FlutterSkillColors.disconnected
            ConnectionState.CONNECTING -> FlutterSkillColors.connecting
            ConnectionState.ERROR -> FlutterSkillColors.errorStatus
        }
    }
}
