package com.aidashboad.flutterskill

import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import com.intellij.openapi.components.Service
import com.intellij.openapi.diagnostic.Logger
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

data class AgentConfig(
    val name: String,
    val displayName: String,
    val configPath: String,
    val detected: Boolean
)

data class McpServerConfig(
    val command: String,
    val args: List<String>
)

@Service(Service.Level.APP)
class McpConfigManager {
    private val logger = Logger.getInstance(McpConfigManager::class.java)
    private val gson: Gson = GsonBuilder().setPrettyPrinting().create()

    companion object {
        @JvmStatic
        fun getInstance(): McpConfigManager {
            return com.intellij.openapi.application.ApplicationManager.getApplication()
                .getService(McpConfigManager::class.java)
        }

        private val FLUTTER_SKILL_CONFIG = McpServerConfig(
            command = "flutter-skill",
            args = listOf("server")
        )
    }

    /**
     * Detect which AI agents are installed on the system
     */
    fun detectAiAgents(): List<AgentConfig> {
        val homeDir = System.getProperty("user.home")
        val agents = mutableListOf<AgentConfig>()

        // Claude Code - check for ~/.claude/ directory or claude command
        // Claude Code uses ~/.claude/settings.json for MCP config
        val claudeDir = "$homeDir/.claude"
        val claudeConfigPath = "$claudeDir/settings.json"
        val claudeDetected = File(claudeDir).exists() || isCommandAvailable("claude")
        agents.add(AgentConfig(
            name = "claude-code",
            displayName = "Claude Code",
            configPath = claudeConfigPath,
            detected = claudeDetected
        ))

        // Cursor - check for ~/.cursor/ directory
        val cursorDir = "$homeDir/.cursor"
        val cursorConfigPath = "$cursorDir/mcp.json"
        agents.add(AgentConfig(
            name = "cursor",
            displayName = "Cursor",
            configPath = cursorConfigPath,
            detected = File(cursorDir).exists()
        ))

        // Windsurf - check for ~/.codeium/windsurf/ directory
        val windsurfDir = "$homeDir/.codeium/windsurf"
        val windsurfConfigPath = "$windsurfDir/mcp_config.json"
        agents.add(AgentConfig(
            name = "windsurf",
            displayName = "Windsurf",
            configPath = windsurfConfigPath,
            detected = File(windsurfDir).exists()
        ))

        return agents
    }

    /**
     * Check if a command is available in PATH
     */
    private fun isCommandAvailable(command: String): Boolean {
        return try {
            val isWindows = System.getProperty("os.name").lowercase().contains("win")
            val checkCommand = if (isWindows) "where" else "which"
            val process = ProcessBuilder(checkCommand, command)
                .redirectErrorStream(true)
                .start()
            process.waitFor() == 0
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Create a backup of the config file
     */
    private fun backupConfig(configPath: String): String? {
        val configFile = File(configPath)
        if (!configFile.exists()) {
            return null
        }

        val timestamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyy-MM-dd-HH-mm-ss"))
        val backupPath = "$configPath.backup-$timestamp"
        Files.copy(configFile.toPath(), File(backupPath).toPath(), StandardCopyOption.REPLACE_EXISTING)
        return backupPath
    }

    /**
     * Merge flutter-skill MCP config into existing config non-destructively
     */
    fun mergeMcpConfig(configPath: String): MergeResult {
        return try {
            val configFile = File(configPath)
            val configDir = configFile.parentFile

            // Ensure parent directory exists
            if (!configDir.exists()) {
                configDir.mkdirs()
            }

            var existingConfig: JsonObject = JsonObject()
            var backupPath: String? = null

            // Read existing config if it exists
            if (configFile.exists()) {
                backupPath = backupConfig(configPath)
                val content = configFile.readText()
                try {
                    existingConfig = gson.fromJson(content, JsonObject::class.java) ?: JsonObject()
                } catch (e: Exception) {
                    return MergeResult(success = false, error = "Invalid JSON in existing config file")
                }
            }

            // Check if flutter-skill is already configured
            val mcpServers = existingConfig.getAsJsonObject("mcpServers")
            if (mcpServers?.has("flutter-skill") == true) {
                return MergeResult(success = true, backupPath = backupPath, alreadyConfigured = true)
            }

            // Merge the config
            val servers = mcpServers ?: JsonObject().also { existingConfig.add("mcpServers", it) }

            val flutterSkillConfig = JsonObject().apply {
                addProperty("command", FLUTTER_SKILL_CONFIG.command)
                add("args", gson.toJsonTree(FLUTTER_SKILL_CONFIG.args))
            }
            servers.add("flutter-skill", flutterSkillConfig)

            // Write back with pretty JSON
            configFile.writeText(gson.toJson(existingConfig) + "\n")

            MergeResult(success = true, backupPath = backupPath)
        } catch (e: Exception) {
            logger.error("Error merging MCP config: ${e.message}", e)
            MergeResult(success = false, error = e.message ?: "Unknown error")
        }
    }

    /**
     * Configure a single agent
     */
    fun configureAgent(agent: AgentConfig): MergeResult {
        return mergeMcpConfig(agent.configPath)
    }

    /**
     * Configure all detected agents
     */
    fun configureAllDetectedAgents(): Map<AgentConfig, MergeResult> {
        val agents = detectAiAgents()
        val results = mutableMapOf<AgentConfig, MergeResult>()

        for (agent in agents.filter { it.detected }) {
            results[agent] = configureAgent(agent)
        }

        return results
    }

    /**
     * Check if any agent already has flutter-skill configured
     */
    fun checkExistingConfigs(): List<AgentConfig> {
        val agents = detectAiAgents()
        val configured = mutableListOf<AgentConfig>()

        for (agent in agents) {
            val configFile = File(agent.configPath)
            if (configFile.exists()) {
                try {
                    val content = configFile.readText()
                    val config = gson.fromJson(content, JsonObject::class.java)
                    if (config?.getAsJsonObject("mcpServers")?.has("flutter-skill") == true) {
                        configured.add(agent)
                    }
                } catch (e: Exception) {
                    // Ignore parse errors
                }
            }
        }

        return configured
    }

    /**
     * Get list of unconfigured but detected agents
     */
    fun getUnconfiguredAgents(): List<AgentConfig> {
        val detected = detectAiAgents().filter { it.detected }
        val configured = checkExistingConfigs().map { it.name }.toSet()
        return detected.filter { it.name !in configured }
    }

    /**
     * Configure MCP for a specific tool by its config path
     */
    fun configureForTool(toolName: String, configPath: String): MergeResult {
        val expandedPath = configPath.replace("~", System.getProperty("user.home"))
        logger.info("Configuring $toolName at $expandedPath")
        return mergeMcpConfig(expandedPath)
    }

    data class MergeResult(
        val success: Boolean,
        val backupPath: String? = null,
        val error: String? = null,
        val alreadyConfigured: Boolean = false
    )
}
