package com.aidashboad.flutterskill

import com.aidashboad.flutterskill.model.UIElement
import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.intellij.openapi.diagnostic.Logger
import kotlinx.coroutines.*
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

/**
 * Response from VM Service operations
 */
data class VmServiceResponse(
    val success: Boolean,
    val data: JsonObject? = null,
    val error: ErrorInfo? = null
) {
    data class ErrorInfo(
        val code: String,
        val message: String
    )
}

/**
 * Complete VM Service Protocol Client for Flutter Skill (IntelliJ Plugin)
 *
 * Provides full integration with Flutter VM Service WebSocket protocol,
 * including all interaction methods, screenshot capabilities, and hot reload.
 *
 * This client handles:
 * - WebSocket connection management
 * - JSON-RPC 2.0 protocol
 * - VM Service extensions (ext.flutter.flutter_skill.*)
 * - Standard VM Service methods (reloadSources, etc.)
 * - Async/await with Kotlin coroutines
 * - Request timeout handling
 * - Connection state management
 * - Error handling and logging
 */
class VmServiceClient(private val uri: String) {
    private val logger = Logger.getInstance(VmServiceClient::class.java)
    private val gson = Gson()

    // WebSocket connection
    private var webSocket: WebSocket? = null
    private val requestIdCounter = AtomicInteger(0)
    private val pendingRequests = ConcurrentHashMap<Int, PendingRequest>()
    private var isolateId: String? = null
    private var isConnected = false

    // Message buffering for multi-part messages
    private val messageBuffer = StringBuilder()

    // Connection timeout
    private val connectionTimeoutMs = 10000L
    private val requestTimeoutMs = 10000L

    /**
     * Pending request tracking
     */
    private data class PendingRequest(
        val future: CompletableFuture<JsonObject>,
        val createdAt: Long = System.currentTimeMillis()
    )

    /**
     * WebSocket Listener implementation
     */
    private inner class VmServiceWebSocketListener : WebSocket.Listener {
        override fun onOpen(webSocket: WebSocket) {
            logger.info("[VmServiceClient] WebSocket connection opened")
            webSocket.request(1)
        }

        override fun onText(webSocket: WebSocket, data: CharSequence, last: Boolean): CompletableFuture<*> {
            messageBuffer.append(data)

            if (last) {
                try {
                    val message = messageBuffer.toString()
                    messageBuffer.clear()

                    logger.debug("[VmServiceClient] Received message: ${message.take(200)}...")

                    val response = JsonParser.parseString(message).asJsonObject
                    handleResponse(response)
                } catch (e: Exception) {
                    logger.error("[VmServiceClient] Failed to parse response", e)
                }
            }

            webSocket.request(1)
            return CompletableFuture.completedFuture(null)
        }

        override fun onError(webSocket: WebSocket, error: Throwable) {
            logger.error("[VmServiceClient] WebSocket error", error)
            isConnected = false

            // Fail all pending requests
            pendingRequests.values.forEach { pending ->
                pending.future.completeExceptionally(error)
            }
            pendingRequests.clear()
        }

        override fun onClose(webSocket: WebSocket, statusCode: Int, reason: String): CompletableFuture<*> {
            logger.info("[VmServiceClient] WebSocket closed: $statusCode - $reason")
            isConnected = false
            return CompletableFuture.completedFuture(null)
        }
    }

    /**
     * Connect to VM Service
     *
     * Establishes WebSocket connection and initializes the main isolate.
     * Throws exception if connection fails or times out.
     */
    suspend fun connect(): Unit = withContext(Dispatchers.IO) {
        if (isConnected) {
            logger.warn("[VmServiceClient] Already connected")
            return@withContext
        }

        logger.info("[VmServiceClient] Connecting to $uri")

        val client = HttpClient.newBuilder()
            .connectTimeout(java.time.Duration.ofMillis(connectionTimeoutMs))
            .build()

        val connectFuture = CompletableFuture<WebSocket>()

        try {
            webSocket = client.newWebSocketBuilder()
                .buildAsync(URI.create(uri), VmServiceWebSocketListener())
                .get(connectionTimeoutMs, TimeUnit.MILLISECONDS)

            // Wait a bit for connection to stabilize
            delay(300)

            // Initialize isolate
            initializeIsolate()

            isConnected = true
            logger.info("[VmServiceClient] Connected successfully")

        } catch (e: Exception) {
            logger.error("[VmServiceClient] Connection failed", e)
            disconnect()
            throw Exception("Failed to connect to VM Service: ${e.message}", e)
        }
    }

    /**
     * Disconnect from VM Service
     *
     * Closes WebSocket connection and cleans up resources.
     */
    fun disconnect() {
        logger.info("[VmServiceClient] Disconnecting...")

        try {
            webSocket?.sendClose(WebSocket.NORMAL_CLOSURE, "Client disconnect")
            webSocket = null
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Error during disconnect", e)
        }

        isConnected = false
        isolateId = null

        // Fail all pending requests
        pendingRequests.values.forEach { pending ->
            pending.future.completeExceptionally(Exception("Disconnected"))
        }
        pendingRequests.clear()

        messageBuffer.clear()
    }

    /**
     * Check if connected
     */
    fun isConnected(): Boolean = isConnected

    /**
     * Initialize and get main isolate ID
     *
     * Calls getVM to retrieve the list of isolates and selects the first one.
     */
    private suspend fun initializeIsolate() {
        logger.info("[VmServiceClient] Initializing isolate...")

        val vm = callMethod("getVM", JsonObject())
        val isolates = vm.getAsJsonArray("isolates")

        if (isolates != null && isolates.size() > 0) {
            isolateId = isolates[0].asJsonObject.get("id").asString
            logger.info("[VmServiceClient] Initialized with isolate: $isolateId")
        } else {
            throw Exception("No isolates found in VM")
        }
    }

    /**
     * Call a VM Service method (JSON-RPC 2.0)
     *
     * Sends a JSON-RPC 2.0 request and waits for the response.
     * Throws exception on timeout or error response.
     */
    private suspend fun callMethod(method: String, params: JsonObject): JsonObject = withContext(Dispatchers.IO) {
        val ws = webSocket ?: throw Exception("Not connected to VM Service")

        val id = requestIdCounter.incrementAndGet()
        val request = JsonObject().apply {
            addProperty("jsonrpc", "2.0")
            addProperty("id", id)
            addProperty("method", method)
            add("params", params)
        }

        val future = CompletableFuture<JsonObject>()
        pendingRequests[id] = PendingRequest(future)

        val requestJson = gson.toJson(request)
        logger.debug("[VmServiceClient] Sending request: ${requestJson.take(200)}...")

        ws.sendText(requestJson, true)

        // Wait for response with timeout
        try {
            withTimeout(requestTimeoutMs) {
                future.await()
            }
        } catch (e: TimeoutCancellationException) {
            pendingRequests.remove(id)
            throw Exception("Request timeout after ${requestTimeoutMs}ms for method: $method")
        } finally {
            // Clean up old pending requests
            cleanupOldRequests()
        }
    }

    /**
     * Handle response from VM Service
     *
     * Matches response ID with pending request and completes the future.
     */
    private fun handleResponse(response: JsonObject) {
        val id = response.get("id")?.asInt
        if (id == null) {
            logger.warn("[VmServiceClient] Received response without ID: $response")
            return
        }

        val pending = pendingRequests.remove(id)
        if (pending == null) {
            logger.warn("[VmServiceClient] Received response for unknown request ID: $id")
            return
        }

        if (response.has("error")) {
            val error = response.getAsJsonObject("error")
            val errorMsg = error.get("message")?.asString ?: "Unknown error"
            val errorCode = error.get("code")?.asInt ?: -1
            logger.warn("[VmServiceClient] Error response: [$errorCode] $errorMsg")
            pending.future.completeExceptionally(Exception("VM Service error [$errorCode]: $errorMsg"))
        } else {
            val result = response.getAsJsonObject("result") ?: JsonObject()
            pending.future.complete(result)
        }
    }

    /**
     * Clean up old pending requests (older than 30 seconds)
     */
    private fun cleanupOldRequests() {
        val now = System.currentTimeMillis()
        val timeout = 30000L

        pendingRequests.entries.removeIf { (id, pending) ->
            if (now - pending.createdAt > timeout) {
                logger.warn("[VmServiceClient] Removing stale request: $id")
                pending.future.completeExceptionally(Exception("Request too old"))
                true
            } else {
                false
            }
        }
    }

    /**
     * Call a service extension (ext.flutter.flutter_skill.*)
     *
     * Wraps callMethod to invoke Flutter Skill extensions.
     * Extension responses have their 'value' field JSON-decoded.
     */
    private suspend fun callExtension(extension: String, params: Map<String, String> = emptyMap()): JsonObject {
        val isolate = isolateId ?: throw Exception("No isolate initialized")

        val methodParams = JsonObject().apply {
            addProperty("isolateId", isolate)
            params.forEach { (key, value) ->
                addProperty(key, value)
            }
        }

        logger.debug("[VmServiceClient] Calling extension: ext.$extension with params: $params")

        val result = callMethod("ext.$extension", methodParams)

        // Parse the response value (it's JSON-encoded string)
        return if (result.has("value")) {
            try {
                val valueStr = result.get("value").asString
                JsonParser.parseString(valueStr).asJsonObject
            } catch (e: Exception) {
                logger.error("[VmServiceClient] Failed to parse extension response", e)
                result
            }
        } else {
            result
        }
    }

    // ==================== PUBLIC API ====================

    /**
     * Get interactive UI elements from Flutter app
     *
     * Calls ext.flutter.flutter_skill.interactive
     * Returns list of UIElement objects with keys, types, positions, etc.
     */
    suspend fun getInteractiveElements(): List<UIElement> {
        return try {
            logger.info("[VmServiceClient] Getting interactive elements...")

            val response = callExtension("flutter.flutter_skill.interactive")

            if (response.get("type")?.asString == "Success") {
                val elements = response.getAsJsonArray("elements")
                val result = elements?.mapNotNull { element ->
                    try {
                        val obj = element.asJsonObject
                        UIElement(
                            key = obj.get("key")?.asString ?: "",
                            type = obj.get("type")?.asString ?: "",
                            text = obj.get("text")?.asString,
                            hint = obj.get("hint")?.asString,
                            value = obj.get("value")?.asString,
                            position = obj.getAsJsonObject("position")?.let {
                                UIElement.Position(
                                    it.get("x")?.asInt ?: 0,
                                    it.get("y")?.asInt ?: 0
                                )
                            },
                            size = obj.getAsJsonObject("size")?.let {
                                UIElement.Size(
                                    it.get("width")?.asInt ?: 0,
                                    it.get("height")?.asInt ?: 0
                                )
                            },
                            enabled = obj.get("enabled")?.asBoolean != false,
                            visible = obj.get("visible")?.asBoolean != false
                        )
                    } catch (e: Exception) {
                        logger.error("[VmServiceClient] Failed to parse element", e)
                        null
                    }
                } ?: emptyList()

                logger.info("[VmServiceClient] Found ${result.size} interactive elements")
                result
            } else {
                logger.warn("[VmServiceClient] Response type is not Success")
                emptyList()
            }
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to get interactive elements", e)
            emptyList()
        }
    }

    /**
     * Tap an element by key or text
     *
     * Calls ext.flutter.flutter_skill.tap
     * Returns VmServiceResponse with success status
     */
    suspend fun tap(key: String? = null, text: String? = null): VmServiceResponse {
        return try {
            logger.info("[VmServiceClient] Tapping element: key=$key, text=$text")

            val params = mutableMapOf<String, String>()
            key?.let { params["key"] = it }
            text?.let { params["text"] = it }

            val response = callExtension("flutter.flutter_skill.tap", params)

            val success = response.get("success")?.asBoolean == true
            if (success) {
                logger.info("[VmServiceClient] Tap successful")
            } else {
                logger.warn("[VmServiceClient] Tap failed: ${response.get("error")}")
            }

            VmServiceResponse(
                success = success,
                data = response,
                error = if (!success && response.has("error")) {
                    val error = response.getAsJsonObject("error")
                    VmServiceResponse.ErrorInfo(
                        code = error.get("code")?.asString ?: "TAP_FAILED",
                        message = error.get("message")?.asString ?: "Tap failed"
                    )
                } else null
            )
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to tap element", e)
            VmServiceResponse(
                success = false,
                error = VmServiceResponse.ErrorInfo("TAP_FAILED", e.message ?: "Failed to tap element")
            )
        }
    }

    /**
     * Enter text into an element
     *
     * Calls ext.flutter.flutter_skill.enterText
     * Returns VmServiceResponse with success status
     */
    suspend fun enterText(key: String, text: String): VmServiceResponse {
        return try {
            logger.info("[VmServiceClient] Entering text in '$key': $text")

            val response = callExtension("flutter.flutter_skill.enterText", mapOf(
                "key" to key,
                "text" to text
            ))

            val success = response.get("success")?.asBoolean == true
            if (success) {
                logger.info("[VmServiceClient] Text entered successfully")
            } else {
                logger.warn("[VmServiceClient] Enter text failed: ${response.get("error")}")
            }

            VmServiceResponse(
                success = success,
                data = response,
                error = if (!success && response.has("error")) {
                    val error = response.getAsJsonObject("error")
                    VmServiceResponse.ErrorInfo(
                        code = error.get("code")?.asString ?: "INPUT_FAILED",
                        message = error.get("message")?.asString ?: "Enter text failed"
                    )
                } else null
            )
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to enter text", e)
            VmServiceResponse(
                success = false,
                error = VmServiceResponse.ErrorInfo("INPUT_FAILED", e.message ?: "Failed to enter text")
            )
        }
    }

    /**
     * Take a screenshot of the entire app
     *
     * Calls ext.flutter.flutter_skill.screenshot
     * Returns base64-encoded PNG image or null
     */
    suspend fun screenshot(quality: Double = 1.0, maxWidth: Int? = null): String? {
        return try {
            logger.info("[VmServiceClient] Taking screenshot (quality=$quality, maxWidth=$maxWidth)")

            val params = mutableMapOf("quality" to quality.toString())
            maxWidth?.let { params["maxWidth"] = it.toString() }

            val response = callExtension("flutter.flutter_skill.screenshot", params)
            val image = response.get("image")?.asString

            if (image != null) {
                logger.info("[VmServiceClient] Screenshot captured (${image.length} chars)")
            } else {
                logger.warn("[VmServiceClient] Screenshot returned null")
            }

            image
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to take screenshot", e)
            null
        }
    }

    /**
     * Take screenshot of a specific element
     *
     * Calls ext.flutter.flutter_skill.screenshotElement
     * Returns base64-encoded PNG image or null
     */
    suspend fun screenshotElement(key: String): String? {
        return try {
            logger.info("[VmServiceClient] Taking element screenshot: $key")

            val response = callExtension("flutter.flutter_skill.screenshotElement", mapOf("key" to key))
            val image = response.get("image")?.asString

            if (image != null) {
                logger.info("[VmServiceClient] Element screenshot captured")
            } else {
                logger.warn("[VmServiceClient] Element screenshot returned null")
            }

            image
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to take element screenshot", e)
            null
        }
    }

    /**
     * Trigger hot reload
     *
     * Calls standard VM Service method 'reloadSources'
     * Returns VmServiceResponse with success status
     */
    suspend fun hotReload(): VmServiceResponse {
        return try {
            val isolate = isolateId ?: throw Exception("No isolate initialized")

            logger.info("[VmServiceClient] Triggering hot reload...")

            val params = JsonObject().apply {
                addProperty("isolateId", isolate)
                addProperty("force", false)
                addProperty("pause", false)
            }

            val result = callMethod("reloadSources", params)
            val success = !result.has("type") || result.get("type")?.asString != "Error"

            if (success) {
                logger.info("[VmServiceClient] Hot reload completed successfully")
            } else {
                logger.warn("[VmServiceClient] Hot reload failed: $result")
            }

            VmServiceResponse(
                success = success,
                data = result
            )
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to hot reload", e)
            VmServiceResponse(
                success = false,
                error = VmServiceResponse.ErrorInfo("HOT_RELOAD_FAILED", e.message ?: "Hot reload failed")
            )
        }
    }

    /**
     * Scroll to make an element visible
     *
     * Calls ext.flutter.flutter_skill.scroll
     * Returns VmServiceResponse with success status
     */
    suspend fun scroll(key: String? = null, text: String? = null): VmServiceResponse {
        return try {
            logger.info("[VmServiceClient] Scrolling to element: key=$key, text=$text")

            val params = mutableMapOf<String, String>()
            key?.let { params["key"] = it }
            text?.let { params["text"] = it }

            val response = callExtension("flutter.flutter_skill.scroll", params)
            val success = response.get("success")?.asBoolean == true

            VmServiceResponse(
                success = success,
                data = response
            )
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to scroll", e)
            VmServiceResponse(
                success = false,
                error = VmServiceResponse.ErrorInfo("SCROLL_FAILED", e.message ?: "Scroll failed")
            )
        }
    }

    /**
     * Long press an element
     *
     * Calls ext.flutter.flutter_skill.longPress
     * Returns VmServiceResponse with success status
     */
    suspend fun longPress(key: String? = null, text: String? = null, duration: Int = 500): VmServiceResponse {
        return try {
            logger.info("[VmServiceClient] Long pressing element: key=$key, text=$text, duration=$duration")

            val params = mutableMapOf("duration" to duration.toString())
            key?.let { params["key"] = it }
            text?.let { params["text"] = it }

            val response = callExtension("flutter.flutter_skill.longPress", params)
            val success = response.get("success")?.asBoolean == true

            VmServiceResponse(
                success = success,
                data = response
            )
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to long press", e)
            VmServiceResponse(
                success = false,
                error = VmServiceResponse.ErrorInfo("LONG_PRESS_FAILED", e.message ?: "Long press failed")
            )
        }
    }

    /**
     * Swipe in a direction
     *
     * Calls ext.flutter.flutter_skill.swipe
     * Returns VmServiceResponse with success status
     */
    suspend fun swipe(direction: String, distance: Double = 300.0, key: String? = null): VmServiceResponse {
        return try {
            logger.info("[VmServiceClient] Swiping: direction=$direction, distance=$distance, key=$key")

            val params = mutableMapOf(
                "direction" to direction,
                "distance" to distance.toString()
            )
            key?.let { params["key"] = it }

            val response = callExtension("flutter.flutter_skill.swipe", params)
            val success = response.get("success")?.asBoolean == true

            VmServiceResponse(
                success = success,
                data = response
            )
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to swipe", e)
            VmServiceResponse(
                success = false,
                error = VmServiceResponse.ErrorInfo("SWIPE_FAILED", e.message ?: "Swipe failed")
            )
        }
    }

    /**
     * Double tap an element
     *
     * Calls ext.flutter.flutter_skill.doubleTap
     * Returns VmServiceResponse with success status
     */
    suspend fun doubleTap(key: String? = null, text: String? = null): VmServiceResponse {
        return try {
            logger.info("[VmServiceClient] Double tapping element: key=$key, text=$text")

            val params = mutableMapOf<String, String>()
            key?.let { params["key"] = it }
            text?.let { params["text"] = it }

            val response = callExtension("flutter.flutter_skill.doubleTap", params)
            val success = response.get("success")?.asBoolean == true

            VmServiceResponse(
                success = success,
                data = response
            )
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to double tap", e)
            VmServiceResponse(
                success = false,
                error = VmServiceResponse.ErrorInfo("DOUBLE_TAP_FAILED", e.message ?: "Double tap failed")
            )
        }
    }

    /**
     * Drag from one element to another
     *
     * Calls ext.flutter.flutter_skill.drag
     * Returns VmServiceResponse with success status
     */
    suspend fun drag(fromKey: String, toKey: String): VmServiceResponse {
        return try {
            logger.info("[VmServiceClient] Dragging from '$fromKey' to '$toKey'")

            val response = callExtension("flutter.flutter_skill.drag", mapOf(
                "fromKey" to fromKey,
                "toKey" to toKey
            ))
            val success = response.get("success")?.asBoolean == true

            VmServiceResponse(
                success = success,
                data = response
            )
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to drag", e)
            VmServiceResponse(
                success = false,
                error = VmServiceResponse.ErrorInfo("DRAG_FAILED", e.message ?: "Drag failed")
            )
        }
    }

    /**
     * Get widget tree structure
     *
     * Calls ext.flutter.flutter_skill.getWidgetTree
     * Returns widget tree JSON or null
     */
    suspend fun getWidgetTree(maxDepth: Int = 10): JsonObject? {
        return try {
            logger.info("[VmServiceClient] Getting widget tree (maxDepth=$maxDepth)")

            val response = callExtension("flutter.flutter_skill.getWidgetTree", mapOf(
                "maxDepth" to maxDepth.toString()
            ))

            response.getAsJsonObject("tree")
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to get widget tree", e)
            null
        }
    }

    /**
     * Get widget properties for a specific key
     *
     * Calls ext.flutter.flutter_skill.getWidgetProperties
     * Returns widget properties JSON or null
     */
    suspend fun getWidgetProperties(key: String): JsonObject? {
        return try {
            logger.info("[VmServiceClient] Getting widget properties for: $key")

            val response = callExtension("flutter.flutter_skill.getWidgetProperties", mapOf("key" to key))

            response.getAsJsonObject("properties")
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to get widget properties", e)
            null
        }
    }

    /**
     * Get all text content on screen
     *
     * Calls ext.flutter.flutter_skill.getTextContent
     * Returns list of text strings
     */
    suspend fun getTextContent(): List<String> {
        return try {
            logger.info("[VmServiceClient] Getting text content")

            val response = callExtension("flutter.flutter_skill.getTextContent")
            val texts = response.getAsJsonArray("texts")

            texts?.map { it.asString } ?: emptyList()
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to get text content", e)
            emptyList()
        }
    }

    /**
     * Find widgets by type
     *
     * Calls ext.flutter.flutter_skill.findByType
     * Returns list of matching elements
     */
    suspend fun findByType(type: String): List<UIElement> {
        return try {
            logger.info("[VmServiceClient] Finding widgets by type: $type")

            val response = callExtension("flutter.flutter_skill.findByType", mapOf("type" to type))
            val elements = response.getAsJsonArray("elements")

            elements?.mapNotNull { element ->
                try {
                    val obj = element.asJsonObject
                    UIElement(
                        key = obj.get("key")?.asString ?: "",
                        type = obj.get("type")?.asString ?: "",
                        text = obj.get("text")?.asString,
                        hint = obj.get("hint")?.asString,
                        value = obj.get("value")?.asString
                    )
                } catch (e: Exception) {
                    logger.error("[VmServiceClient] Failed to parse element", e)
                    null
                }
            } ?: emptyList()
        } catch (e: Exception) {
            logger.error("[VmServiceClient] Failed to find by type", e)
            emptyList()
        }
    }
}

// ==================== COROUTINE EXTENSIONS ====================

/**
 * Extension function to convert CompletableFuture to suspend function
 */
private suspend fun <T> CompletableFuture<T>.await(): T = suspendCoroutine { cont ->
    whenComplete { result, error ->
        if (error != null) {
            cont.resumeWithException(error)
        } else {
            cont.resume(result)
        }
    }
}
