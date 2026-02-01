package com.aidashboad.flutterskill

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.Service
import java.io.File

/**
 * Detects installed AI CLI tools on the system
 */
@Service(Service.Level.APP)
class AiToolDetector {

    data class AiTool(
        val name: String,
        val command: String,
        val configPath: String?,
        val installed: Boolean,
        val version: String?,
        val description: String
    )

    companion object {
        fun getInstance(): AiToolDetector =
            ApplicationManager.getApplication().getService(AiToolDetector::class.java)

        private val AI_TOOLS = listOf(
            AiToolDef("Claude Code", "claude", "~/.claude/settings.json", "Anthropic's AI coding assistant"),
            AiToolDef("Cursor", "cursor", "~/.cursor/mcp.json", "AI-first code editor"),
            AiToolDef("Windsurf", "windsurf", "~/.codeium/windsurf/mcp_config.json", "Codeium's AI IDE"),
            AiToolDef("Continue", "continue", "~/.continue/config.json", "Open-source AI code assistant"),
            AiToolDef("Aider", "aider", null, "AI pair programming in terminal"),
            AiToolDef("GitHub Copilot", "gh copilot", null, "GitHub's AI coding assistant"),
            AiToolDef("OpenAI CLI", "openai", null, "OpenAI API command line tool"),
            AiToolDef("Gemini CLI", "gemini", null, "Google's Gemini CLI"),
            AiToolDef("Ollama", "ollama", null, "Run LLMs locally"),
            AiToolDef("LM Studio", "lms", null, "Local LLM server"),
        )

        private data class AiToolDef(
            val name: String,
            val command: String,
            val configPath: String?,
            val description: String
        )
    }

    private var cachedTools: List<AiTool>? = null

    fun detectTools(forceRefresh: Boolean = false): List<AiTool> {
        if (!forceRefresh && cachedTools != null) {
            return cachedTools!!
        }

        cachedTools = AI_TOOLS.map { def ->
            val (installed, version) = checkCommand(def.command)
            val configExists = def.configPath?.let {
                File(it.replace("~", System.getProperty("user.home"))).exists()
            } ?: false

            AiTool(
                name = def.name,
                command = def.command,
                configPath = def.configPath,
                installed = installed || configExists,
                version = version,
                description = def.description
            )
        }

        return cachedTools!!
    }

    fun getInstalledTools(): List<AiTool> = detectTools().filter { it.installed }

    fun getMcpConfigurableTools(): List<AiTool> = detectTools().filter {
        it.installed && it.configPath != null
    }

    private fun checkCommand(command: String): Pair<Boolean, String?> {
        return try {
            val parts = command.split(" ")
            val process = ProcessBuilder(listOf("which", parts[0]))
                .redirectErrorStream(true)
                .start()
            val result = process.waitFor()

            if (result == 0) {
                // Try to get version
                val version = try {
                    val versionProcess = ProcessBuilder(listOf(parts[0], "--version"))
                        .redirectErrorStream(true)
                        .start()
                    versionProcess.waitFor()
                    val output = versionProcess.inputStream.bufferedReader().readText().trim()
                    if (output.length < 100) output.lines().firstOrNull() else null
                } catch (e: Exception) {
                    null
                }
                Pair(true, version)
            } else {
                Pair(false, null)
            }
        } catch (e: Exception) {
            Pair(false, null)
        }
    }
}
