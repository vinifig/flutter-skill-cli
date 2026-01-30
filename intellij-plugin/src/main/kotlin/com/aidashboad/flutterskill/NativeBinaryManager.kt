package com.aidashboad.flutterskill

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.Service
import com.intellij.openapi.diagnostic.Logger
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
        const val VERSION = "0.2.14"

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
        val path = getLocalBinaryPath() ?: return false
        return File(path).exists()
    }

    fun getBestBinaryPath(): Pair<String, Boolean> {
        val localPath = getLocalBinaryPath()
        if (localPath != null && File(localPath).exists()) {
            return Pair(localPath, true)
        }
        // Fallback to dart command
        return Pair("dart", false)
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
