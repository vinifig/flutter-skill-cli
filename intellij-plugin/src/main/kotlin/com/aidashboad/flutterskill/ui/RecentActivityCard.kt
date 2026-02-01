package com.aidashboad.flutterskill.ui

import com.aidashboad.flutterskill.model.ActivityEntry
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.DialogWrapper
import com.intellij.ui.components.JBList
import com.intellij.ui.components.JBScrollPane
import com.intellij.util.ui.JBUI
import java.awt.Component
import java.awt.Dimension
import java.awt.FlowLayout
import javax.swing.*

/**
 * Card showing recent activity history
 */
class RecentActivityCard(project: Project) : CardComponent(project) {
    private val activities = mutableListOf<ActivityEntry>()
    private val maxDisplayCount = 5  // Show 5 items for consistency with VSCode
    private val maxStoredCount = 20  // Store up to 20 items

    override fun buildContent() {
        addTitle("Recent Activity", "📜")

        if (activities.isEmpty()) {
            // Empty state
            val emptyPanel = JPanel()
            emptyPanel.layout = BoxLayout(emptyPanel, BoxLayout.Y_AXIS)
            emptyPanel.alignmentX = Component.LEFT_ALIGNMENT
            emptyPanel.isOpaque = false

            val iconLabel = JLabel("📜")
            iconLabel.font = iconLabel.font.deriveFont(48f)
            iconLabel.foreground = FlutterSkillColors.textSecondary
            iconLabel.alignmentX = Component.CENTER_ALIGNMENT

            val textLabel = JLabel("No recent activity")
            textLabel.foreground = FlutterSkillColors.textSecondary
            textLabel.font = textLabel.font.deriveFont(12f)
            textLabel.alignmentX = Component.CENTER_ALIGNMENT

            emptyPanel.add(Box.createVerticalStrut(JBUI.scale(16)))
            emptyPanel.add(iconLabel)
            emptyPanel.add(Box.createVerticalStrut(JBUI.scale(8)))
            emptyPanel.add(textLabel)
            emptyPanel.add(Box.createVerticalStrut(JBUI.scale(16)))

            panel.add(emptyPanel)
        } else {
            // Activity list
            val listModel = DefaultListModel<ActivityEntry>()
            val displayActivities = activities.take(maxDisplayCount)
            for (activity in displayActivities) {
                listModel.addElement(activity)
            }

            val list = JBList(listModel)
            list.cellRenderer = ActivityCellRenderer()

            val scrollPane = JBScrollPane(list)
            scrollPane.alignmentX = Component.LEFT_ALIGNMENT
            scrollPane.preferredSize = Dimension(Integer.MAX_VALUE, JBUI.scale(150))
            scrollPane.maximumSize = Dimension(Integer.MAX_VALUE, JBUI.scale(150))
            panel.add(scrollPane)
            panel.add(Box.createVerticalStrut(JBUI.scale(8)))

            // Action buttons panel
            val actionsPanel = JPanel(FlowLayout(FlowLayout.LEFT, 8, 0))
            actionsPanel.alignmentX = Component.LEFT_ALIGNMENT
            actionsPanel.isOpaque = false

            // View All button (if there are more items)
            if (activities.size > maxDisplayCount) {
                val viewAllBtn = createButton("View All (${activities.size})") {
                    showAllActivities()
                }
                actionsPanel.add(viewAllBtn)
            }

            // Clear button
            val clearBtn = createButton("Clear") {
                clearHistory()
            }
            actionsPanel.add(clearBtn)

            panel.add(actionsPanel)
        }
    }

    /**
     * Add a new activity entry
     */
    fun addActivity(entry: ActivityEntry) {
        // Add to beginning (most recent first)
        activities.add(0, entry)

        // Limit stored size
        if (activities.size > maxStoredCount) {
            activities.removeAt(activities.size - 1)
        }

        refresh()
    }

    /**
     * Clear all history
     */
    private fun clearHistory() {
        val result = JOptionPane.showConfirmDialog(
            panel,
            "Clear all activity history?",
            "Clear History",
            JOptionPane.YES_NO_OPTION
        )
        if (result == JOptionPane.YES_OPTION) {
            activities.clear()
            refresh()
        }
    }

    /**
     * Show all activities in a dialog
     */
    private fun showAllActivities() {
        val listModel = DefaultListModel<ActivityEntry>()
        for (activity in activities) {
            listModel.addElement(activity)
        }

        val list = JBList(listModel)
        list.cellRenderer = ActivityCellRenderer()

        val scrollPane = JBScrollPane(list)
        scrollPane.preferredSize = Dimension(JBUI.scale(400), JBUI.scale(300))

        JOptionPane.showMessageDialog(
            panel,
            scrollPane,
            "All Activity (${activities.size} items)",
            JOptionPane.PLAIN_MESSAGE
        )
    }

    /**
     * Get all activities
     */
    fun getActivities(): List<ActivityEntry> {
        return activities.toList()
    }

    /**
     * Custom cell renderer for activity entries
     */
    private class ActivityCellRenderer : ListCellRenderer<ActivityEntry> {
        override fun getListCellRendererComponent(
            list: JList<out ActivityEntry>?,
            value: ActivityEntry?,
            index: Int,
            isSelected: Boolean,
            cellHasFocus: Boolean
        ): Component {
            val panel = JPanel()
            panel.layout = BoxLayout(panel, BoxLayout.Y_AXIS)
            panel.border = JBUI.Borders.empty(6, 8)
            panel.background = if (isSelected) {
                FlutterSkillColors.hoverBackground
            } else {
                FlutterSkillColors.bg1
            }

            if (value != null) {
                // Header with icon and description
                val headerPanel = JPanel()
                headerPanel.layout = BoxLayout(headerPanel, BoxLayout.X_AXIS)
                headerPanel.isOpaque = false

                val iconLabel = JLabel(value.type.getIcon())
                iconLabel.font = iconLabel.font.deriveFont(12f)

                val descLabel = JLabel(value.description)
                descLabel.font = descLabel.font.deriveFont(11f)
                descLabel.foreground = if (value.success) {
                    FlutterSkillColors.success
                } else {
                    FlutterSkillColors.error
                }

                headerPanel.add(iconLabel)
                headerPanel.add(Box.createHorizontalStrut(JBUI.scale(6)))
                headerPanel.add(descLabel)
                headerPanel.add(Box.createHorizontalGlue())

                panel.add(headerPanel)

                // Timestamp
                val timeLabel = JLabel(value.getRelativeTime())
                timeLabel.font = timeLabel.font.deriveFont(10f)
                timeLabel.foreground = FlutterSkillColors.textSecondary
                panel.add(timeLabel)
            }

            return panel
        }
    }
}
