package com.aidashboad.flutterskill

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.startup.ProjectActivity
import com.intellij.openapi.wm.ToolWindowManager

class FlutterSkillStartupActivity : ProjectActivity {
    override suspend fun execute(project: Project) {
        val service = FlutterSkillService.getInstance(project)
        service.initialize()

        // Auto-open the tool window if it's a Flutter project
        if (service.isFlutterProject()) {
            ApplicationManager.getApplication().invokeLater {
                val toolWindow = ToolWindowManager.getInstance(project)
                    .getToolWindow("Flutter Skill")
                toolWindow?.show()
            }
        }
    }
}
