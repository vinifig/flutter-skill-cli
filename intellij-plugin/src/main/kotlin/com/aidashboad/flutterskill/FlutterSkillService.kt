package com.aidashboad.flutterskill

import com.aidashboad.flutterskill.model.ActivityEntry
import com.aidashboad.flutterskill.model.UIElement
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.OSProcessHandler
import com.intellij.execution.process.ProcessAdapter
import com.intellij.execution.process.ProcessEvent
import com.intellij.notification.NotificationAction
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.components.Service
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Key
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

@Service(Service.Level.PROJECT)
class FlutterSkillService(private val project: Project) {

    private var mcpProcess: OSProcessHandler? = null
    private val logger = Logger.getInstance(FlutterSkillService::class.java)
    private var initialized = false
    private val scanner = VmServiceScanner.getInstance(project)
    private var onElementsUpdate: ((List<UIElement>) -> Unit)? = null
    private var onActivityAdd: ((ActivityEntry) -> Unit)? = null

    companion object {
        fun getInstance(project: Project): FlutterSkillService {
            return project.getService(FlutterSkillService::class.java)
        }
    }

    /**
     * Register callback for elements update
     */
    fun onElementsUpdate(callback: (List<UIElement>) -> Unit) {
        onElementsUpdate = callback
    }

    /**
     * Register callback for activity add
     */
    fun onActivityAdd(callback: (ActivityEntry) -> Unit) {
        onActivityAdd = callback
    }

    /**
     * Initialize the service - called on project open
     */
    fun initialize() {
        if (initialized) return
        initialized = true

        // Only proceed if this is a Flutter project
        if (!isFlutterProject()) {
            return
        }

        logger.info("Flutter project detected, initializing Flutter Skill")

        // Start VM service scanning
        VmServiceScanner.getInstance(project).start()

        // Auto-start MCP server
        startMcpServer()

        // Check if agents need configuration
        promptConfigureAgentsIfNeeded()

        // Download native binary in background for faster startup
        NativeBinaryManager.getInstance().downloadNativeBinaryAsync()

        // Check for updates (once per 24 hours)
        UpdateChecker.getInstance().checkForUpdatesAsync(project)
    }

    /**
     * Check if the current project is a Flutter project
     */
    fun isFlutterProject(): Boolean {
        val basePath = project.basePath ?: return false
        val pubspecFile = File("$basePath/pubspec.yaml")

        if (!pubspecFile.exists()) {
            return false
        }

        // Check if pubspec contains flutter dependency
        return try {
            val content = pubspecFile.readText()
            content.contains("flutter:") || content.contains("flutter_test:")
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Prompt to configure AI agents if not already configured
     */
    private fun promptConfigureAgentsIfNeeded() {
        val configManager = McpConfigManager.getInstance()
        val unconfiguredAgents = configManager.getUnconfiguredAgents()

        if (unconfiguredAgents.isEmpty()) {
            logger.info("All detected AI agents already have flutter-skill configured")
            return
        }

        val agentNames = unconfiguredAgents.joinToString(", ") { it.displayName }

        NotificationGroupManager.getInstance()
            .getNotificationGroup("Flutter Skill")
            .createNotification(
                "Configure AI Agents",
                "Flutter Skill detected: $agentNames. Configure MCP integration?",
                NotificationType.INFORMATION
            )
            .addAction(NotificationAction.createSimple("Configure") {
                promptConfigureAgents()
            })
            .addAction(NotificationAction.createSimple("Later") {
                // Do nothing
            })
            .notify(project)
    }

    /**
     * Show configuration dialog for AI agents
     */
    fun promptConfigureAgents() {
        val configManager = McpConfigManager.getInstance()
        val results = configManager.configureAllDetectedAgents()

        val successCount = results.count { it.value.success }
        val failCount = results.count { !it.value.success }
        val alreadyConfigured = results.count { it.value.alreadyConfigured }

        val message = buildString {
            if (successCount > 0) {
                append("Configured $successCount agent(s). ")
            }
            if (alreadyConfigured > 0) {
                append("$alreadyConfigured already configured. ")
            }
            if (failCount > 0) {
                val failedAgents = results.filter { !it.value.success }.keys.joinToString(", ") { it.displayName }
                append("Failed: $failedAgents")
            }
            if (successCount > 0) {
                append("\nRestart your AI agents to use Flutter Skill tools.")
            }
        }

        val type = if (failCount > 0) NotificationType.WARNING else NotificationType.INFORMATION

        notify(message, type)
    }

    fun launchApp() {
        val basePath = project.basePath ?: return
        runCommand("dart", listOf("pub", "global", "run", "flutter_skill", "launch", "."), basePath)
        notify("Flutter app launching with Flutter Skill...")
    }

    fun inspect() {
        logger.info("Inspecting UI elements...")
        addActivity(ActivityEntry.ActivityType.INSPECT, "Inspecting UI elements...", true)

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val elements = scanner.getInteractiveElements()

                withContext(Dispatchers.Main) {
                    if (elements.isNotEmpty()) {
                        onElementsUpdate?.invoke(elements)
                        addActivity(
                            ActivityEntry.ActivityType.INSPECT,
                            "Found ${elements.size} interactive elements",
                            true
                        )
                        notify("Found ${elements.size} interactive elements")
                    } else {
                        addActivity(ActivityEntry.ActivityType.INSPECT, "No interactive elements found", true)
                        notify("No interactive elements found. Make sure your Flutter app is running.")
                    }
                }
            } catch (e: Exception) {
                logger.error("Error inspecting elements: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    addActivity(ActivityEntry.ActivityType.INSPECT, "Failed to inspect UI", false, e.message)
                    notify("Failed to inspect: ${e.message}", NotificationType.ERROR)
                }
            }
        }
    }

    fun screenshot() {
        logger.info("Taking screenshot...")
        addActivity(ActivityEntry.ActivityType.SCREENSHOT, "Taking screenshot...", true)

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val base64Image = scanner.takeScreenshot()

                withContext(Dispatchers.Main) {
                    if (base64Image != null) {
                        // Save screenshot to file
                        saveScreenshot(base64Image)
                        addActivity(ActivityEntry.ActivityType.SCREENSHOT, "Screenshot saved", true)
                    } else {
                        addActivity(ActivityEntry.ActivityType.SCREENSHOT, "Screenshot failed", false)
                        notify("Failed to capture screenshot", NotificationType.ERROR)
                    }
                }
            } catch (e: Exception) {
                logger.error("Error taking screenshot: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    addActivity(ActivityEntry.ActivityType.SCREENSHOT, "Screenshot failed", false, e.message)
                    notify("Error: ${e.message}", NotificationType.ERROR)
                }
            }
        }
    }

    /**
     * Save screenshot to file
     */
    private fun saveScreenshot(base64Image: String) {
        try {
            val projectPath = project.basePath ?: return
            val screenshotsDir = File(projectPath, "screenshots")
            if (!screenshotsDir.exists()) {
                screenshotsDir.mkdirs()
            }

            val timestamp = System.currentTimeMillis()
            val filename = "flutter_screenshot_$timestamp.png"
            val file = File(screenshotsDir, filename)

            // Decode base64 and save
            val imageBytes = java.util.Base64.getDecoder().decode(base64Image)
            file.writeBytes(imageBytes)

            notify("Screenshot saved to: ${file.absolutePath}")
            logger.info("Screenshot saved to: ${file.absolutePath}")
        } catch (e: Exception) {
            logger.error("Error saving screenshot: ${e.message}", e)
            notify("Failed to save screenshot: ${e.message}", NotificationType.ERROR)
        }
    }

    /**
     * Add activity entry
     */
    private fun addActivity(
        type: ActivityEntry.ActivityType,
        description: String,
        success: Boolean,
        details: String? = null
    ) {
        val entry = ActivityEntry(
            type = type,
            description = description,
            success = success,
            details = details
        )
        onActivityAdd?.invoke(entry)
    }

    fun startMcpServer() {
        if (mcpProcess != null && !mcpProcess!!.isProcessTerminated) {
            logger.info("MCP Server is already running")
            return
        }

        val (binaryPath, isNative) = NativeBinaryManager.getInstance().getBestBinaryPath()

        val commandLine = if (isNative) {
            logger.info("Using native binary: $binaryPath")
            GeneralCommandLine(binaryPath, "server")
        } else {
            logger.info("Using Dart runtime (native binary not available)")
            GeneralCommandLine("dart", "pub", "global", "run", "flutter_skill", "server")
        }

        mcpProcess = OSProcessHandler(commandLine)

        mcpProcess?.addProcessListener(object : ProcessAdapter() {
            override fun processTerminated(event: ProcessEvent) {
                logger.info("MCP Server stopped")
            }

            override fun onTextAvailable(event: ProcessEvent, outputType: Key<*>) {
                // Log output if needed
            }
        })

        mcpProcess?.startNotify()
        logger.info("MCP Server started")
    }

    fun stopMcpServer() {
        mcpProcess?.destroyProcess()
        mcpProcess = null
    }

    private fun runCommand(command: String, args: List<String>, workDir: String) {
        val commandLine = GeneralCommandLine(command)
        commandLine.addParameters(args)
        commandLine.workDirectory = java.io.File(workDir)

        val handler = OSProcessHandler(commandLine)
        handler.startNotify()
    }

    private fun notify(message: String, type: NotificationType = NotificationType.INFORMATION) {
        NotificationGroupManager.getInstance()
            .getNotificationGroup("Flutter Skill")
            .createNotification(message, type)
            .notify(project)
    }
}
