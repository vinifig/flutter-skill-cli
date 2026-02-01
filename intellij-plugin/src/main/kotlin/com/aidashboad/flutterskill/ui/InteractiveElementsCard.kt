package com.aidashboad.flutterskill.ui

import com.aidashboad.flutterskill.VmServiceScanner
import com.aidashboad.flutterskill.model.UIElement
import com.intellij.openapi.project.Project
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.treeStructure.Tree
import com.intellij.util.ui.JBUI
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.awt.BorderLayout
import java.awt.Component
import java.awt.Dimension
import java.awt.FlowLayout
import javax.swing.*
import javax.swing.tree.DefaultMutableTreeNode
import javax.swing.tree.DefaultTreeCellRenderer
import javax.swing.tree.DefaultTreeModel

/**
 * Card showing interactive elements in a tree view with search
 */
class InteractiveElementsCard(project: Project) : CardComponent(project) {
    private val elements = mutableListOf<UIElement>()
    private var tree: Tree? = null
    private var searchField: JTextField? = null

    override fun buildContent() {
        addTitle("Interactive Elements", "📱")

        if (elements.isEmpty()) {
            // Empty state
            val emptyPanel = JPanel()
            emptyPanel.layout = BoxLayout(emptyPanel, BoxLayout.Y_AXIS)
            emptyPanel.alignmentX = Component.LEFT_ALIGNMENT
            emptyPanel.isOpaque = false

            val iconLabel = JLabel("📱")
            iconLabel.font = iconLabel.font.deriveFont(48f)
            iconLabel.foreground = FlutterSkillColors.textSecondary
            iconLabel.alignmentX = Component.CENTER_ALIGNMENT

            val textLabel = JLabel("No elements found")
            textLabel.foreground = FlutterSkillColors.textSecondary
            textLabel.font = textLabel.font.deriveFont(12f)
            textLabel.alignmentX = Component.CENTER_ALIGNMENT

            emptyPanel.add(Box.createVerticalStrut(JBUI.scale(16)))
            emptyPanel.add(iconLabel)
            emptyPanel.add(Box.createVerticalStrut(JBUI.scale(8)))
            emptyPanel.add(textLabel)
            emptyPanel.add(Box.createVerticalStrut(JBUI.scale(16)))

            val inspectBtn = createButton("Inspect App") {
                com.aidashboad.flutterskill.FlutterSkillService.getInstance(project).inspect()
            }
            inspectBtn.alignmentX = Component.CENTER_ALIGNMENT
            emptyPanel.add(inspectBtn)

            panel.add(emptyPanel)
        } else {
            // Search field
            searchField = JTextField()
            searchField!!.toolTipText = "Search elements..."
            searchField!!.alignmentX = Component.LEFT_ALIGNMENT
            searchField!!.maximumSize = Dimension(Integer.MAX_VALUE, JBUI.scale(28))
            panel.add(searchField!!)
            panel.add(Box.createVerticalStrut(JBUI.scale(8)))

            // Tree view
            val rootNode = DefaultMutableTreeNode("Elements (${elements.size})")
            for (element in elements) {
                val node = DefaultMutableTreeNode(element)
                rootNode.add(node)
            }

            tree = Tree(DefaultTreeModel(rootNode))
            tree!!.cellRenderer = ElementTreeCellRenderer()
            tree!!.isRootVisible = true
            tree!!.showsRootHandles = true

            val scrollPane = JBScrollPane(tree)
            scrollPane.alignmentX = Component.LEFT_ALIGNMENT
            scrollPane.preferredSize = Dimension(Integer.MAX_VALUE, JBUI.scale(200))
            scrollPane.maximumSize = Dimension(Integer.MAX_VALUE, JBUI.scale(200))
            panel.add(scrollPane)
            panel.add(Box.createVerticalStrut(JBUI.scale(8)))

            // Action buttons
            val actionsPanel = JPanel(FlowLayout(FlowLayout.LEFT, 8, 0))
            actionsPanel.alignmentX = Component.LEFT_ALIGNMENT
            actionsPanel.isOpaque = false

            val tapBtn = createButton("👆 Tap") {
                performAction("tap")
            }
            val inputBtn = createButton("⌨️ Input") {
                performAction("input")
            }
            val inspectBtn = createButton("🔍 Inspect") {
                performAction("inspect")
            }

            actionsPanel.add(tapBtn)
            actionsPanel.add(inputBtn)
            actionsPanel.add(inspectBtn)
            panel.add(actionsPanel)
        }
    }

    /**
     * Update elements list
     */
    fun updateElements(newElements: List<UIElement>) {
        elements.clear()
        elements.addAll(newElements)
        refresh()
    }

    /**
     * Perform action on selected element
     */
    private fun performAction(action: String) {
        val selectedNode = tree?.selectionPath?.lastPathComponent as? DefaultMutableTreeNode
        val element = selectedNode?.userObject as? UIElement

        if (element == null) {
            JOptionPane.showMessageDialog(
                panel,
                "Please select an element first",
                "No Selection",
                JOptionPane.WARNING_MESSAGE
            )
            return
        }

        val scanner = VmServiceScanner.getInstance(project)

        when (action) {
            "tap" -> {
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val result = scanner.performTap(element.key, element.text)
                        withContext(Dispatchers.Main) {
                            if (result.success) {
                                JOptionPane.showMessageDialog(
                                    panel,
                                    "Tapped element: ${element.key}",
                                    "Success",
                                    JOptionPane.INFORMATION_MESSAGE
                                )
                            } else {
                                JOptionPane.showMessageDialog(
                                    panel,
                                    "Failed to tap: ${result.error?.message}",
                                    "Error",
                                    JOptionPane.ERROR_MESSAGE
                                )
                            }
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            JOptionPane.showMessageDialog(
                                panel,
                                "Error: ${e.message}",
                                "Error",
                                JOptionPane.ERROR_MESSAGE
                            )
                        }
                    }
                }
            }
            "input" -> {
                if (element.isInputElement()) {
                    val input = JOptionPane.showInputDialog(
                        panel,
                        "Enter text for ${element.key}:",
                        "Input Text",
                        JOptionPane.PLAIN_MESSAGE
                    )
                    if (input != null && input.isNotEmpty()) {
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val result = scanner.performEnterText(element.key ?: "", input)
                                withContext(Dispatchers.Main) {
                                    if (result.success) {
                                        JOptionPane.showMessageDialog(
                                            panel,
                                            "Text entered successfully",
                                            "Success",
                                            JOptionPane.INFORMATION_MESSAGE
                                        )
                                    } else {
                                        JOptionPane.showMessageDialog(
                                            panel,
                                            "Failed to enter text: ${result.error?.message}",
                                            "Error",
                                            JOptionPane.ERROR_MESSAGE
                                        )
                                    }
                                }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    JOptionPane.showMessageDialog(
                                        panel,
                                        "Error: ${e.message}",
                                        "Error",
                                        JOptionPane.ERROR_MESSAGE
                                    )
                                }
                            }
                        }
                    }
                } else {
                    JOptionPane.showMessageDialog(
                        panel,
                        "Element is not an input field",
                        "Invalid Element",
                        JOptionPane.WARNING_MESSAGE
                    )
                }
            }
            "inspect" -> {
                // Show element details (synchronous - no VM call needed)
                JOptionPane.showMessageDialog(
                    panel,
                    element.getDescription(),
                    "Element Details: ${element.key}",
                    JOptionPane.INFORMATION_MESSAGE
                )
            }
        }
    }

    /**
     * Custom tree cell renderer for elements
     */
    private class ElementTreeCellRenderer : DefaultTreeCellRenderer() {
        override fun getTreeCellRendererComponent(
            tree: JTree?,
            value: Any?,
            sel: Boolean,
            expanded: Boolean,
            leaf: Boolean,
            row: Int,
            hasFocus: Boolean
        ): Component {
            super.getTreeCellRendererComponent(tree, value, sel, expanded, leaf, row, hasFocus)

            if (value is DefaultMutableTreeNode) {
                val userObject = value.userObject
                if (userObject is UIElement) {
                    text = "${userObject.getIcon()} ${userObject.key} (${userObject.type})"
                }
            }

            return this
        }
    }
}
