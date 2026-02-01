package com.aidashboad.flutterskill

import com.intellij.ide.plugins.PluginManagerCore
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.Service
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.extensions.PluginId
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

@Service(Service.Level.APP)
class NativeBinaryManager {
    private val logger = Logger.getInstance(NativeBinaryManager::class.java)

    companion object {
        // Read version from plugin descriptor dynamically
        @JvmStatic
        fun getVersion(): String {
            return try {
                val pluginId = PluginId.getId("com.aidashboad.flutter-skill")
                val plugin = PluginManagerCore.getPlugin(pluginId)
                plugin?.version ?: "0.4.0" // Fallback version
            } catch (e: Exception) {
                "0.4.0" // Fallback version
            }
        }

        // For backward compatibility, use the function
        @JvmStatic
        val VERSION: String
            get() = getVersion()

        @JvmStatic
        fun getInstance(): NativeBinaryManager {
            return ApplicationManager.getApplication().getService(NativeBinaryManager::class.java)
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

        fun getLocalBinaryPath(): String? {
            val binaryName = getBinaryName() ?: return null
            return File(getCacheDir(), "$binaryName-v$VERSION").absolutePath
        }
    }

    fun hasNativeBinary(): Boolean {
        val path = getLatestBinaryPath() ?: return false
        return File(path).exists()
    }

    fun getBestBinaryPath(): Pair<String, Boolean> {
        // 优先使用最新版本的 binary
        val latestPath = getLatestBinaryPath()
        if (latestPath != null && File(latestPath).exists()) {
            return Pair(latestPath, true)
        }

        // 其次使用当前版本
        val localPath = getLocalBinaryPath()
        if (localPath != null && File(localPath).exists()) {
            return Pair(localPath, true)
        }

        // Fallback to dart command
        return Pair("dart", false)
    }

    /**
     * 获取最新下载的 binary 路径（支持自动更新后的新版本）
     */
    private fun getLatestBinaryPath(): String? {
        val binaryName = getBinaryName() ?: return null
        val cacheDir = getCacheDir()

        if (!cacheDir.exists()) return null

        // 找到所有匹配的 binary 文件，选择版本最新的
        val binaries = cacheDir.listFiles { file ->
            file.name.startsWith(binaryName) && file.name.contains("-v")
        } ?: return null

        // 按版本号排序，返回最新的
        return binaries
            .mapNotNull { file ->
                val versionMatch = Regex("-v(\\d+\\.\\d+\\.\\d+)").find(file.name)
                versionMatch?.let { Pair(file, it.groupValues[1]) }
            }
            .maxByOrNull { (_, version) ->
                val parts = version.split(".").map { it.toIntOrNull() ?: 0 }
                parts.getOrElse(0) { 0 } * 10000 + parts.getOrElse(1) { 0 } * 100 + parts.getOrElse(2) { 0 }
            }
            ?.first?.absolutePath
    }

    fun downloadNativeBinaryAsync(onComplete: (success: Boolean) -> Unit = {}) {
        if (hasNativeBinary()) {
            onComplete(true)
            return
        }

        val binaryName = getBinaryName()
        if (binaryName == null) {
            logger.info("No native binary available for this platform")
            onComplete(false)
            return
        }

        val localPath = getLocalBinaryPath() ?: return

        ProgressManager.getInstance().run(object : Task.Backgroundable(null, "Flutter Skill: Downloading native binary", false) {
            override fun run(indicator: ProgressIndicator) {
                indicator.isIndeterminate = false
                indicator.text = "Downloading flutter-skill native binary..."

                val downloadUrl = "https://github.com/ai-dashboad/flutter-skill/releases/download/v$VERSION/$binaryName"

                try {
                    downloadFile(downloadUrl, localPath, indicator)
                    // Make executable
                    File(localPath).setExecutable(true)
                    logger.info("Native binary downloaded to $localPath")
                    onComplete(true)
                } catch (e: Exception) {
                    logger.warn("Failed to download native binary: ${e.message}")
                    onComplete(false)
                }
            }
        })
    }

    private fun downloadFile(urlString: String, destPath: String, indicator: ProgressIndicator) {
        val destFile = File(destPath)
        destFile.parentFile?.mkdirs()

        var connection: HttpURLConnection? = null
        var currentUrl = urlString

        // Follow redirects
        repeat(5) {
            val url = URL(currentUrl)
            connection = url.openConnection() as HttpURLConnection
            connection!!.instanceFollowRedirects = false

            when (connection!!.responseCode) {
                HttpURLConnection.HTTP_MOVED_PERM, HttpURLConnection.HTTP_MOVED_TEMP, HttpURLConnection.HTTP_SEE_OTHER -> {
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
}
