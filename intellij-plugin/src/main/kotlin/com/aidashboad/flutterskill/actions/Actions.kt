package com.aidashboad.flutterskill.actions

import com.aidashboad.flutterskill.FlutterSkillService
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent

class LaunchAction : AnAction() {
    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        FlutterSkillService.getInstance(project).launchApp()
    }
}

class InspectAction : AnAction() {
    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        FlutterSkillService.getInstance(project).inspect()
    }
}

class ScreenshotAction : AnAction() {
    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        FlutterSkillService.getInstance(project).screenshot()
    }
}

class StartMcpAction : AnAction() {
    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        FlutterSkillService.getInstance(project).startMcpServer()
    }
}
