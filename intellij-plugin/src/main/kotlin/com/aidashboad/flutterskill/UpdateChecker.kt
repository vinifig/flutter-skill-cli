package com.aidashboad.flutterskill

import com.intellij.ide.BrowserUtil
import com.intellij.ide.util.PropertiesComponent
import com.intellij.notification.NotificationAction
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.Service
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.project.Project
import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

@Service(Service.Level.APP)
class UpdateChecker {
    private val logger = Logger.getInstance(UpdateChecker::class.java)
    private val gson = Gson()

    companion object {
        private const val CHECK_INTERVAL_HOURS = 24L
        private const val LAST_CHECK_KEY = "flutter-skill.lastUpdateCheck"
        private const val SKIPPED_VERSION_KEY = "flutter-skill.skippedVersion"
        private const val AUTO_UPDATE_KEY = "flutter-skill.autoUpdate"

        // Read current version dynamically from plugin descriptor
        private val CURRENT_VERSION: String
            get() = NativeBinaryManager.VERSION

        @JvmStatic
        fun getInstance(): UpdateChecker {
            return ApplicationManager.getApplication().getService(UpdateChecker::class.java)
        }

        private fun getCacheDir(): File {
            val homeDir = System.getProperty("user.home")
            return File("$homeDir/.flutter-skill/bin")
        }

        private fun getBinaryName(): String? {
            val os = System.getProperty("os.name").lowercase()
            val arch = System.getProperty("os.arch").lowercase()

            return when {
                os.contains("mac") && (arch == "aarch64" || arch == "arm64") -> "flutter-skill-macos-arm64"
                os.contains("mac") -> "flutter-skill-macos-x64"
                os.contains("linux") -> "flutter-skill-linux-x64"
                os.contains("win") -> "flutter-skill-windows-x64.exe"
                else -> null
            }
        }
    }

    fun checkForUpdatesAsync(project: Project) {
        ApplicationManager.getApplication().executeOnPooledThread {
            checkForUpdates(project)
        }
    }

    private fun checkForUpdates(project: Project) {
        val properties = PropertiesComponent.getInstance()

        // Check if we should check (once per 24 hours)
        val lastCheck = properties.getLong(LAST_CHECK_KEY, 0)
        val now = System.currentTimeMillis()
        val hoursSinceLastCheck = TimeUnit.MILLISECONDS.toHours(now - lastCheck)

        if (hoursSinceLastCheck < CHECK_INTERVAL_HOURS) {
            return
        }

        // Update last check time
        properties.setValue(LAST_CHECK_KEY, now.toString())

        logger.info("Checking for updates...")

        val latestVersion = getLatestVersionFromGitHub() ?: run {
            logger.info("Could not check for updates from GitHub")
            return
        }

        logger.info("Current: $CURRENT_VERSION, Latest: $latestVersion")

        // Check if update available
        if (compareVersions(latestVersion, CURRENT_VERSION) <= 0) {
            logger.info("Already on latest version")
            return
        }

        // Check if user skipped this version
        val skippedVersion = properties.getValue(SKIPPED_VERSION_KEY)
        if (skippedVersion == latestVersion) {
            logger.info("User skipped this version")
            return
        }

        // Auto-download the new native binary
        autoDownloadUpdate(project, latestVersion)
    }

    /**
     * 从 GitHub releases 获取最新版本
     */
    private fun getLatestVersionFromGitHub(): String? {
        return try {
            val url = URL("https://api.github.com/repos/ai-dashboad/flutter-skill/releases/latest")
            val connection = url.openConnection() as HttpURLConnection
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.setRequestProperty("Accept", "application/vnd.github.v3+json")

            if (connection.responseCode != 200) {
                // Fallback to npm registry
                return getLatestVersionFromNpm()
            }

            val response = connection.inputStream.bufferedReader().readText()
            val json = gson.fromJson(response, JsonObject::class.java)
            val tagName = json.get("tag_name")?.asString ?: return null

            // Remove 'v' prefix if present
            tagName.removePrefix("v")
        } catch (e: Exception) {
            logger.warn("Error checking GitHub for updates: ${e.message}")
            getLatestVersionFromNpm()
        }
    }

    private fun getLatestVersionFromNpm(): String? {
        return try {
            val url = URL("https://registry.npmjs.org/flutter-skill-mcp")
            val connection = url.openConnection() as HttpURLConnection
            connection.connectTimeout = 5000
            connection.readTimeout = 5000

            if (connection.responseCode != 200) {
                return null
            }

            val response = connection.inputStream.bufferedReader().readText()
            val json = gson.fromJson(response, JsonObject::class.java)
            json.getAsJsonObject("dist-tags")?.get("latest")?.asString
        } catch (e: Exception) {
            logger.warn("Error checking npm for updates: ${e.message}")
            null
        }
    }

    /**
     * 自动从 GitHub 下载更新
     */
    private fun autoDownloadUpdate(project: Project, latestVersion: String) {
        val binaryName = getBinaryName()
        if (binaryName == null) {
            logger.info("No native binary available for this platform, skipping auto-update")
            showManualUpdateNotification(project, latestVersion)
            return
        }

        val downloadUrl = "https://github.com/ai-dashboad/flutter-skill/releases/download/v$latestVersion/$binaryName"
        val destPath = File(getCacheDir(), "$binaryName-v$latestVersion").absolutePath

        // 如果已经下载过这个版本，直接通知更新完成
        if (File(destPath).exists()) {
            logger.info("Version $latestVersion already downloaded")
            showUpdateCompleteNotification(project, latestVersion)
            return
        }

        // 后台下载新版本
        ProgressManager.getInstance().run(object : Task.Backgroundable(project, "Flutter Skill: Downloading update v$latestVersion", false) {
            override fun run(indicator: ProgressIndicator) {
                indicator.isIndeterminate = false
                indicator.text = "Downloading Flutter Skill v$latestVersion..."

                try {
                    downloadFile(downloadUrl, destPath, indicator)
                    File(destPath).setExecutable(true)
                    logger.info("Auto-update downloaded to $destPath")

                    // 显示更新完成通知
                    ApplicationManager.getApplication().invokeLater {
                        showUpdateCompleteNotification(project, latestVersion)
                    }
                } catch (e: Exception) {
                    logger.warn("Auto-update failed: ${e.message}")
                    ApplicationManager.getApplication().invokeLater {
                        showUpdateFailedNotification(project, latestVersion, e.message)
                    }
                }
            }
        })
    }

    private fun showUpdateCompleteNotification(project: Project, version: String) {
        NotificationGroupManager.getInstance()
            .getNotificationGroup("Flutter Skill")
            .createNotification(
                "Flutter Skill Updated",
                "Successfully updated to v$version. Restart MCP server to use new version.",
                NotificationType.INFORMATION
            )
            .addAction(NotificationAction.createSimple("Restart MCP Server") {
                FlutterSkillService.getInstance(project).apply {
                    stopMcpServer()
                    startMcpServer()
                }
            })
            .addAction(NotificationAction.createSimple("View Changes") {
                BrowserUtil.browse("https://github.com/ai-dashboad/flutter-skill/releases/tag/v$version")
            })
            .notify(project)
    }

    private fun showUpdateFailedNotification(project: Project, version: String, error: String?) {
        val properties = PropertiesComponent.getInstance()

        NotificationGroupManager.getInstance()
            .getNotificationGroup("Flutter Skill")
            .createNotification(
                "Update Failed",
                "Failed to auto-update to v$version: ${error ?: "Unknown error"}",
                NotificationType.WARNING
            )
            .addAction(NotificationAction.createSimple("Retry") {
                autoDownloadUpdate(project, version)
            })
            .addAction(NotificationAction.createSimple("Download Manually") {
                BrowserUtil.browse("https://github.com/ai-dashboad/flutter-skill/releases/tag/v$version")
            })
            .addAction(NotificationAction.createSimple("Skip This Version") {
                properties.setValue(SKIPPED_VERSION_KEY, version)
            })
            .notify(project)
    }

    private fun showManualUpdateNotification(project: Project, version: String) {
        val properties = PropertiesComponent.getInstance()

        NotificationGroupManager.getInstance()
            .getNotificationGroup("Flutter Skill")
            .createNotification(
                "Update Available",
                "Flutter Skill v$version is available (current: $CURRENT_VERSION)",
                NotificationType.INFORMATION
            )
            .addAction(NotificationAction.createSimple("Download") {
                BrowserUtil.browse("https://github.com/ai-dashboad/flutter-skill/releases/tag/v$version")
            })
            .addAction(NotificationAction.createSimple("View Changes") {
                BrowserUtil.browse("https://github.com/ai-dashboad/flutter-skill/releases/tag/v$version")
            })
            .addAction(NotificationAction.createSimple("Skip This Version") {
                properties.setValue(SKIPPED_VERSION_KEY, version)
            })
            .notify(project)
    }

    private fun downloadFile(urlString: String, destPath: String, indicator: ProgressIndicator) {
        val destFile = File(destPath)
        destFile.parentFile?.mkdirs()

        var connection: HttpURLConnection? = null
        var currentUrl = urlString

        // Follow redirects (GitHub uses redirects for release assets)
        repeat(5) {
            val url = URL(currentUrl)
            connection = url.openConnection() as HttpURLConnection
            connection!!.instanceFollowRedirects = false

            when (connection!!.responseCode) {
                HttpURLConnection.HTTP_MOVED_PERM, HttpURLConnection.HTTP_MOVED_TEMP, HttpURLConnection.HTTP_SEE_OTHER, 307 -> {
                    currentUrl = connection!!.getHeaderField("Location")
                    connection!!.disconnect()
                    return@repeat
                }
                HttpURLConnection.HTTP_OK -> return@repeat
                else -> throw Exception("HTTP ${connection!!.responseCode}")
            }
        }

        connection?.let { conn ->
            val totalBytes = conn.contentLengthLong
            var downloadedBytes = 0L

            conn.inputStream.use { input ->
                FileOutputStream(destFile).use { output ->
                    val buffer = ByteArray(8192)
                    var bytesRead: Int

                    while (input.read(buffer).also { bytesRead = it } != -1) {
                        output.write(buffer, 0, bytesRead)
                        downloadedBytes += bytesRead

                        if (totalBytes > 0) {
                            indicator.fraction = downloadedBytes.toDouble() / totalBytes
                            indicator.text = "Downloading... ${(downloadedBytes * 100 / totalBytes)}%"
                        }
                    }
                }
            }
        }
    }

    private fun compareVersions(v1: String, v2: String): Int {
        val parts1 = v1.split(".").map { it.toIntOrNull() ?: 0 }
        val parts2 = v2.split(".").map { it.toIntOrNull() ?: 0 }

        for (i in 0 until maxOf(parts1.size, parts2.size)) {
            val p1 = parts1.getOrNull(i) ?: 0
            val p2 = parts2.getOrNull(i) ?: 0
            if (p1 > p2) return 1
            if (p1 < p2) return -1
        }
        return 0
    }
}
