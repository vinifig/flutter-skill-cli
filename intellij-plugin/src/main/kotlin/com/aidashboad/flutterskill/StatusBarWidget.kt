package com.aidashboad.flutterskill

import com.intellij.icons.AllIcons
import com.intellij.ide.DataManager
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.popup.JBPopupFactory
import com.intellij.openapi.wm.StatusBar
import com.intellij.openapi.wm.StatusBarWidget
import com.intellij.openapi.wm.StatusBarWidgetFactory
import com.intellij.util.Consumer
import java.awt.event.MouseEvent
import javax.swing.Icon

class FlutterSkillStatusBarWidgetFactory : StatusBarWidgetFactory {
    companion object {
        const val ID = "FlutterSkillStatus"
    }

    override fun getId(): String = ID

    override fun getDisplayName(): String = "Flutter Skill"

    override fun isAvailable(project: Project): Boolean {
        return FlutterSkillService.getInstance(project).isFlutterProject()
    }

    override fun createWidget(project: Project): StatusBarWidget {
        return FlutterSkillStatusBarWidget(project)
    }

    override fun disposeWidget(widget: StatusBarWidget) {
        // Widget cleanup handled by dispose()
    }

    override fun canBeEnabledOn(statusBar: StatusBar): Boolean = true
}

class FlutterSkillStatusBarWidget(private val project: Project) : StatusBarWidget, StatusBarWidget.IconPresentation {
    private var statusBar: StatusBar? = null
    private var currentState: ConnectionState = ConnectionState.DISCONNECTED
    private var currentService: VmServiceInfo? = null

    init {
        // Subscribe to state changes from VmServiceScanner
        VmServiceScanner.getInstance(project).onStateChange { state, service ->
            currentState = state
            currentService = service
            statusBar?.updateWidget(ID())
        }
    }

    override fun ID(): String = FlutterSkillStatusBarWidgetFactory.ID

    override fun getPresentation(): StatusBarWidget.WidgetPresentation = this

    override fun install(statusBar: StatusBar) {
        this.statusBar = statusBar
    }

    override fun dispose() {
        statusBar = null
    }

    override fun getIcon(): Icon {
        return when (currentState) {
            ConnectionState.DISCONNECTED -> AllIcons.Debugger.Db_disabled_breakpoint
            ConnectionState.CONNECTING -> AllIcons.Process.Step_1
            ConnectionState.CONNECTED -> AllIcons.Debugger.Db_verified_breakpoint
            ConnectionState.ERROR -> AllIcons.General.Error
        }
    }

    override fun getTooltipText(): String {
        return when (currentState) {
            ConnectionState.DISCONNECTED -> "Flutter Skill: No app connected"
            ConnectionState.CONNECTING -> "Flutter Skill: Connecting..."
            ConnectionState.CONNECTED -> currentService?.let {
                "Flutter Skill: Connected to port ${it.port}"
            } ?: "Flutter Skill: Connected"
            ConnectionState.ERROR -> "Flutter Skill: Connection error"
        }
    }

    override fun getClickConsumer(): Consumer<MouseEvent>? {
        return Consumer { event ->
            showStatusPopup(event)
        }
    }

    private fun showStatusPopup(event: MouseEvent) {
        val service = FlutterSkillService.getInstance(project)

        val popup = JBPopupFactory.getInstance()
            .createActionGroupPopup(
                "Flutter Skill",
                createActionGroup(service),
                DataManager.getInstance().getDataContext(event.component),
                JBPopupFactory.ActionSelectionAid.SPEEDSEARCH,
                false
            )

        popup.showUnderneathOf(event.component)
    }

    private fun createActionGroup(service: FlutterSkillService): DefaultActionGroup {
        val group = DefaultActionGroup()

        if (currentState == ConnectionState.DISCONNECTED || currentState == ConnectionState.ERROR) {
            group.add(object : AnAction("Launch Flutter App", "Start a Flutter app with Flutter Skill", AllIcons.Actions.Execute) {
                override fun actionPerformed(e: AnActionEvent) {
                    service.launchApp()
                }
            })

            group.add(object : AnAction("Scan for Running Apps", "Scan ports for running Flutter apps", AllIcons.Actions.Find) {
                override fun actionPerformed(e: AnActionEvent) {
                    VmServiceScanner.getInstance(project).rescan()
                }
            })
        }

        if (currentState == ConnectionState.CONNECTED) {
            group.add(object : AnAction("Inspect UI", "View the widget tree", AllIcons.Actions.Preview) {
                override fun actionPerformed(e: AnActionEvent) {
                    service.inspect()
                }
            })

            group.add(object : AnAction("Take Screenshot", "Capture app screenshot", AllIcons.Actions.Dump) {
                override fun actionPerformed(e: AnActionEvent) {
                    service.screenshot()
                }
            })
        }

        group.addSeparator()

        group.add(object : AnAction("Configure AI Agents", "Set up MCP integration", AllIcons.General.Settings) {
            override fun actionPerformed(e: AnActionEvent) {
                service.promptConfigureAgents()
            }
        })

        return group
    }
}
