package com.flutterskill

import android.app.Activity
import android.app.Application
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.ScrollView
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.*
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList

/**
 * FlutterSkillBridge — Embedded HTTP + WebSocket server for the flutter-skill
 * bridge protocol. Enables AI agents to inspect, interact with, and automate
 * native Android applications.
 *
 * Usage:
 *   class MyApp : Application() {
 *       override fun onCreate() {
 *           super.onCreate()
 *           if (BuildConfig.DEBUG) {
 *               FlutterSkillBridge.start(this, appName = "MyApp")
 *           }
 *       }
 *   }
 */
object FlutterSkillBridge {

    private const val TAG = "FlutterSkillBridge"
    private const val SDK_VERSION = "1.0.0"
    private const val DEFAULT_PORT = 18118
    private const val MAX_LOG_ENTRIES = 500
    private const val MAX_WS_PAYLOAD_BYTES = 16 * 1024 * 1024 // 16 MB

    private var serverSocket: ServerSocket? = null
    private var application: Application? = null
    private var appName: String = "android-app"
    private var currentActivity: Activity? = null
    private var isRunning = false

    private val mainHandler = Handler(Looper.getMainLooper())
    private var scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val logBuffer = CopyOnWriteArrayList<String>()

    // Capabilities advertised in health check
    private val capabilities = listOf(
        "initialize", "screenshot", "screenshot_region", "screenshot_element", "inspect", "inspect_interactive", "tap", "enter_text",
        "swipe", "scroll", "find_element", "get_text", "wait_for_element",
        "get_logs", "clear_logs", "go_back", "press_key",
    )

    // ---------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------

    /**
     * Start the bridge server. Call from Application.onCreate() or Activity.onCreate(),
     * ideally guarded by a debug build check.
     *
     * @param app     The Application instance.
     * @param appName Human-readable application name for discovery.
     * @param port    Port to listen on (default 18118).
     */
    fun start(app: Application, appName: String = "android-app", port: Int = DEFAULT_PORT) {
        if (isRunning) {
            Log.w(TAG, "Bridge server already running")
            return
        }
        this.application = app
        this.appName = appName

        // Create a fresh CoroutineScope (previous one may have been cancelled by stop())
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

        // Track current activity via lifecycle callbacks
        app.registerActivityLifecycleCallbacks(activityTracker)

        // Start the server
        scope.launch {
            startServer(port)
        }

        Log.i(TAG, "flutter-skill bridge started on port $port")
    }

    /**
     * Stop the bridge server and release resources.
     */
    fun stop() {
        isRunning = false
        try {
            serverSocket?.close()
        } catch (_: Exception) {}
        serverSocket = null
        application?.unregisterActivityLifecycleCallbacks(activityTracker)
        scope.cancel()
        Log.i(TAG, "flutter-skill bridge stopped")
    }

    /**
     * Append a log entry to the bridge log buffer.
     * Apps can call this to surface custom log messages to agents.
     */
    fun log(level: String, message: String) {
        val entry = "[$level] $message"
        logBuffer.add(entry)
        while (logBuffer.size > MAX_LOG_ENTRIES) {
            logBuffer.removeAt(0)
        }
    }

    // ---------------------------------------------------------------
    // Activity lifecycle tracking
    // ---------------------------------------------------------------

    private val activityTracker = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            currentActivity = activity
        }
        override fun onActivityPaused(activity: Activity) {
            // Don't null out currentActivity immediately — the new activity
            // will set it in onResumed. This prevents a race condition where
            // go_back fails because currentActivity is null between pause/resume.
        }
        override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) {}
        override fun onActivityStarted(activity: Activity) {}
        override fun onActivityStopped(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {
            if (currentActivity == activity) currentActivity = null
        }
    }

    // ---------------------------------------------------------------
    // HTTP + WebSocket Server
    // ---------------------------------------------------------------

    private suspend fun startServer(port: Int) {
        isRunning = true
        try {
            serverSocket = ServerSocket(port, 50, InetAddress.getByName("127.0.0.1"))
            Log.i(TAG, "Listening on port $port")

            while (isRunning) {
                val client = try {
                    serverSocket?.accept() ?: break
                } catch (_: Exception) {
                    break
                }
                scope.launch { handleClient(client) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Server error: ${e.message}")
        }
    }

    private suspend fun handleClient(socket: Socket) {
        try {
            socket.soTimeout = 30_000
            val input = BufferedInputStream(socket.getInputStream())
            val output = BufferedOutputStream(socket.getOutputStream())

            // Read HTTP request line and headers
            val requestLine = readLine(input)
            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = readLine(input)
                if (line.isEmpty()) break
                val colon = line.indexOf(':')
                if (colon > 0) {
                    headers[line.substring(0, colon).trim().lowercase()] =
                        line.substring(colon + 1).trim()
                }
            }

            val parts = requestLine.split(" ")
            val method = parts.getOrElse(0) { "GET" }
            val path = parts.getOrElse(1) { "/" }

            // WebSocket upgrade
            if (path == "/ws" && headers["upgrade"]?.lowercase() == "websocket") {
                handleWebSocketUpgrade(socket, input, output, headers)
                return
            }

            // Health check endpoint
            if (method == "GET" && path == "/.flutter-skill") {
                val json = JSONObject().apply {
                    put("framework", "android-native")
                    put("app_name", appName)
                    put("platform", "android")
                    put("sdk_version", SDK_VERSION)
                    put("capabilities", JSONArray(capabilities))
                }
                sendHttpResponse(output, 200, "application/json", json.toString())
            } else {
                sendHttpResponse(output, 404, "text/plain", "Not Found")
            }

            socket.close()
        } catch (e: Exception) {
            Log.d(TAG, "Client handler error: ${e.message}")
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun sendHttpResponse(
        output: OutputStream,
        status: Int,
        contentType: String,
        body: String
    ) {
        val statusText = when (status) {
            200 -> "OK"
            404 -> "Not Found"
            else -> "Error"
        }
        val bodyBytes = body.toByteArray(StandardCharsets.UTF_8)
        val header = "HTTP/1.1 $status $statusText\r\n" +
            "Content-Type: $contentType\r\n" +
            "Content-Length: ${bodyBytes.size}\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        output.write(header.toByteArray(StandardCharsets.UTF_8))
        output.write(bodyBytes)
        output.flush()
    }

    // ---------------------------------------------------------------
    // WebSocket handling (RFC 6455 minimal implementation)
    // ---------------------------------------------------------------

    private suspend fun handleWebSocketUpgrade(
        socket: Socket,
        input: BufferedInputStream,
        output: BufferedOutputStream,
        headers: Map<String, String>
    ) {
        val key = headers["sec-websocket-key"] ?: return
        val acceptKey = computeWebSocketAccept(key)

        val response = "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: $acceptKey\r\n" +
            "\r\n"
        output.write(response.toByteArray(StandardCharsets.UTF_8))
        output.flush()

        socket.soTimeout = 0 // No timeout for WebSocket

        // Enter WebSocket frame loop
        try {
            while (isRunning && !socket.isClosed) {
                val frame = readWebSocketFrame(input) ?: break

                when (frame.opcode) {
                    0x01 -> { // Text frame
                        val text = String(frame.payload, StandardCharsets.UTF_8)
                        // Handle text ping keepalive
                        if (text == "ping") {
                            writeWebSocketFrame(output, 0x01, "pong".toByteArray(StandardCharsets.UTF_8))
                        } else {
                            val responseText = handleJsonRpc(text)
                            writeWebSocketFrame(output, 0x01, responseText.toByteArray(StandardCharsets.UTF_8))
                        }
                    }
                    0x08 -> break // Close
                    0x09 -> { // Ping -> Pong
                        writeWebSocketFrame(output, 0x0A, frame.payload)
                    }
                    0x0A -> {} // Pong — ignore
                }
            }
        } catch (e: Exception) {
            Log.d(TAG, "WebSocket closed: ${e.message}")
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun computeWebSocketAccept(key: String): String {
        val magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        val sha1 = MessageDigest.getInstance("SHA-1").digest(magic.toByteArray(StandardCharsets.UTF_8))
        return Base64.encodeToString(sha1, Base64.NO_WRAP)
    }

    private data class WsFrame(val opcode: Int, val payload: ByteArray)

    private fun readWebSocketFrame(input: InputStream): WsFrame? {
        val b0 = input.read()
        if (b0 == -1) return null
        val b1 = input.read()
        if (b1 == -1) return null

        val opcode = b0 and 0x0F
        val masked = (b1 and 0x80) != 0
        var payloadLen = (b1 and 0x7F).toLong()

        if (payloadLen == 126L) {
            val hi = input.read()
            val lo = input.read()
            if (hi == -1 || lo == -1) return null
            payloadLen = ((hi shl 8) or lo).toLong()
        } else if (payloadLen == 127L) {
            var len = 0L
            for (i in 0 until 8) {
                val b = input.read()
                if (b == -1) return null
                len = (len shl 8) or b.toLong()
            }
            payloadLen = len
        }

        if (payloadLen > MAX_WS_PAYLOAD_BYTES) {
            throw IOException("WebSocket payload too large: $payloadLen bytes (max $MAX_WS_PAYLOAD_BYTES)")
        }

        val mask = if (masked) {
            val m = ByteArray(4)
            readFully(input, m)
            m
        } else null

        val payload = ByteArray(payloadLen.toInt())
        readFully(input, payload)

        if (mask != null) {
            for (i in payload.indices) {
                payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
            }
        }

        return WsFrame(opcode, payload)
    }

    private fun writeWebSocketFrame(output: OutputStream, opcode: Int, payload: ByteArray) {
        // FIN bit set, no masking (server -> client)
        output.write(0x80 or opcode)

        val len = payload.size
        if (len < 126) {
            output.write(len)
        } else if (len < 65536) {
            output.write(126)
            output.write((len shr 8) and 0xFF)
            output.write(len and 0xFF)
        } else {
            output.write(127)
            for (i in 7 downTo 0) {
                output.write((len shr (8 * i)) and 0xFF)
            }
        }

        output.write(payload)
        output.flush()
    }

    private fun readFully(input: InputStream, buffer: ByteArray) {
        var offset = 0
        while (offset < buffer.size) {
            val read = input.read(buffer, offset, buffer.size - offset)
            if (read == -1) throw IOException("Unexpected end of stream")
            offset += read
        }
    }

    private fun readLine(input: InputStream): String {
        val sb = StringBuilder()
        while (true) {
            val ch = input.read()
            if (ch == -1 || ch == '\n'.code) break
            if (ch != '\r'.code) sb.append(ch.toChar())
        }
        return sb.toString()
    }

    // ---------------------------------------------------------------
    // JSON-RPC 2.0 dispatcher
    // ---------------------------------------------------------------

    private fun handleJsonRpc(text: String): String {
        val request: JSONObject
        try {
            request = JSONObject(text)
        } catch (e: Exception) {
            Log.e(TAG, "JSON-RPC parse error: ${e.message}")
            return buildRpcError(null, -32700, "Parse error: ${e.message}")
        }

        val id = request.opt("id")
        val method = request.optString("method", "")

        if (method.isEmpty()) {
            return buildRpcError(id, -32600, "Invalid request")
        }

        return try {
            val params = request.optJSONObject("params") ?: JSONObject()
            val result = dispatchMethod(method, params)
            buildRpcResponse(id, result)
        } catch (e: NoSuchMethodException) {
            buildRpcError(id, -32601, e.message ?: "Method not found")
        } catch (e: Exception) {
            Log.e(TAG, "JSON-RPC error: ${e.message}")
            buildRpcError(id, -32603, "Internal error: ${e.message}")
        }
    }

    private fun buildRpcResponse(id: Any?, result: JSONObject): String {
        return JSONObject().apply {
            put("jsonrpc", "2.0")
            put("id", id ?: JSONObject.NULL)
            put("result", result)
        }.toString()
    }

    private fun buildRpcError(id: Any?, code: Int, message: String): String {
        return JSONObject().apply {
            put("jsonrpc", "2.0")
            put("id", id ?: JSONObject.NULL)
            put("error", JSONObject().apply {
                put("code", code)
                put("message", message)
            })
        }.toString()
    }

    private fun dispatchMethod(method: String, params: JSONObject): JSONObject {
        return when (method) {
            "initialize"          -> handleInitialize()
            "inspect"             -> handleInspect(params)
            "inspect_interactive" -> handleInspectInteractive(params)
            "tap"                 -> handleTap(params)
            "enter_text"          -> handleEnterText(params)
            "swipe"               -> handleSwipe(params)
            "scroll"              -> handleScroll(params)
            "find_element"        -> handleFindElement(params)
            "get_text"            -> handleGetText(params)
            "wait_for_element"    -> handleWaitForElement(params)
            "screenshot"          -> handleScreenshot()
            "screenshot_region"   -> handleScreenshotRegion(params)
            "screenshot_element"  -> handleScreenshotElement(params)
            "get_logs"            -> handleGetLogs()
            "clear_logs"          -> handleClearLogs()
            "go_back"             -> handleGoBack()
            "press_key"           -> handlePressKey(params)
            "long_press"          -> handleLongPress(params)
            "double_tap"          -> handleDoubleTap(params)
            "drag"                -> handleDrag(params)
            "tap_at"              -> handleTapAt(params)
            "long_press_at"       -> handleLongPressAt(params)
            "edge_swipe"          -> handleEdgeSwipe(params)
            "gesture"             -> handleGesture(params)
            "scroll_until_visible" -> handleScrollUntilVisible(params)
            "swipe_coordinates"   -> handleSwipeCoordinates(params)
            "get_checkbox_state"  -> handleGetCheckboxState(params)
            "get_slider_value"    -> handleGetSliderValue(params)
            "get_route"           -> handleGetRoute()
            "get_navigation_stack" -> handleGetNavigationStack()
            "get_errors"          -> handleGetErrors()
            "get_performance"     -> handleGetPerformance()
            "get_frame_stats"     -> handleGetFrameStats()
            "get_memory_stats"    -> handleGetMemoryStats()
            "wait_for_gone"       -> handleWaitForGone(params)
            "diagnose"            -> handleDiagnose()
            "enable_test_indicators" -> handleEnableTestIndicators()
            "get_indicator_status" -> handleGetIndicatorStatus()
            "enable_network_monitoring" -> handleEnableNetworkMonitoring()
            "get_network_requests" -> handleGetNetworkRequests()
            "clear_network_requests" -> handleClearNetworkRequests()
            else -> throw NoSuchMethodException("Method not found: $method")
        }
    }

    // ---------------------------------------------------------------
    // Bridge method implementations
    // ---------------------------------------------------------------

    private fun handleInitialize(): JSONObject {
        return JSONObject().apply {
            put("success", true)
            put("framework", "android-native")
            put("sdk_version", SDK_VERSION)
            put("platform", "android")
            put("os_version", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        }
    }

    private fun handleInspect(params: JSONObject): JSONObject {
        val activity = currentActivity
            ?: return JSONObject().apply { put("elements", JSONArray()) }

        val elements = runOnMainThreadBlocking {
            val rootView = activity.window.decorView.rootView
            ViewTraversal.collectElements(rootView, interactiveOnly = true)
        }

        val jsonElements = JSONArray()
        for (el in elements) {
            jsonElements.put(mapToJsonObject(el))
        }

        return JSONObject().apply {
            put("elements", jsonElements)
        }
    }

    private fun handleInspectInteractive(params: JSONObject): JSONObject {
        val activity = currentActivity
            ?: return JSONObject().apply { 
                put("elements", JSONArray())
                put("summary", "No active activity")
            }

        val result = runOnMainThreadBlocking {
            val rootView = activity.window.decorView.rootView
            ViewTraversal.collectInteractiveElementsStructured(rootView)
        }

        val jsonElements = JSONArray()
        for (el in result.first) {
            jsonElements.put(mapToJsonObject(el))
        }

        return JSONObject().apply {
            put("elements", jsonElements)
            put("summary", result.second)
        }
    }

    private fun handleTap(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val refId = params.optString("ref", "")
        
        if (key.isEmpty() && refId.isEmpty()) {
            return JSONObject().apply {
                put("success", false)
                put("message", "Missing 'key' or 'ref' parameter")
            }
        }

        val activity = currentActivity
            ?: return JSONObject().apply {
                put("success", false)
                put("message", "No active activity")
            }

        val result = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            var view: View? = null
            var method = "unknown"

            // Try ref ID first if provided
            if (refId.isNotEmpty()) {
                view = findViewByRefId(root, refId)
                method = "ref"
            }

            // Fallback to key if ref not found or not provided
            if (view == null && key.isNotEmpty()) {
                view = ViewTraversal.findByKey(root, key)
                method = "key"
            }

            if (view != null) {
                view.performClick()
                Pair(true, method)
            } else {
                Pair(false, method)
            }
        }

        return JSONObject().apply {
            put("success", result.first)
            put("message", if (result.first) "Tapped via ${result.second}" else "Element not found")
            put("method", result.second)
        }
    }

    private fun handleEnterText(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val refId = params.optString("ref", "")
        val text = params.optString("text", "")
        
        if (key.isEmpty() && refId.isEmpty()) {
            return JSONObject().apply {
                put("success", false)
                put("message", "Missing 'key' or 'ref' parameter")
            }
        }

        val activity = currentActivity
            ?: return JSONObject().apply {
                put("success", false)
                put("message", "No active activity")
            }

        val result = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            var view: View? = null
            var method = "unknown"

            // Try ref ID first if provided
            if (refId.isNotEmpty()) {
                view = findViewByRefId(root, refId)
                method = "ref"
            }

            // Fallback to key if ref not found or not provided
            if (view == null && key.isNotEmpty()) {
                view = ViewTraversal.findByKey(root, key)
                method = "key"
            }

            if (view is EditText) {
                view.requestFocus()
                view.setText(text)
                view.setSelection(text.length)
                Pair(true, method)
            } else {
                Pair(false, method)
            }
        }

        return JSONObject().apply {
            put("success", result.first)
            put("message", if (result.first) "Text entered via ${result.second}" else "EditText not found")
            put("method", result.second)
        }
    }

    private fun handleSwipe(params: JSONObject): JSONObject {
        val direction = params.optString("direction", "up")
        val distance = params.optInt("distance", 500)
        val key = params.optString("key", "")

        val activity = currentActivity
            ?: return JSONObject().apply {
                put("success", false)
                put("message", "No active activity")
            }

        val success = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            val target = if (key.isNotEmpty()) ViewTraversal.findByKey(root, key) else root

            if (target == null) return@runOnMainThreadBlocking false

            val location = IntArray(2)
            target.getLocationOnScreen(location)
            val cx = location[0] + target.width / 2f
            val cy = location[1] + target.height / 2f

            var dx = 0f
            var dy = 0f
            when (direction) {
                "up"    -> dy = -distance.toFloat()
                "down"  -> dy = distance.toFloat()
                "left"  -> dx = -distance.toFloat()
                "right" -> dx = distance.toFloat()
            }

            dispatchSwipeGesture(target, cx, cy, cx + dx, cy + dy)
            true
        }

        return JSONObject().apply {
            put("success", success)
        }
    }

    private fun dispatchSwipeGesture(
        target: View, startX: Float, startY: Float, endX: Float, endY: Float
    ) {
        val downTime = SystemClock.uptimeMillis()
        val steps = 10
        val stepDuration = 10L // ms per step

        // Down event
        val downEvent = MotionEvent.obtain(
            downTime, downTime, MotionEvent.ACTION_DOWN, startX, startY, 0
        )
        target.dispatchTouchEvent(downEvent)
        downEvent.recycle()

        // Move events
        for (i in 1..steps) {
            val fraction = i.toFloat() / steps
            val x = startX + (endX - startX) * fraction
            val y = startY + (endY - startY) * fraction
            val eventTime = downTime + i * stepDuration
            val moveEvent = MotionEvent.obtain(
                downTime, eventTime, MotionEvent.ACTION_MOVE, x, y, 0
            )
            target.dispatchTouchEvent(moveEvent)
            moveEvent.recycle()
        }

        // Up event
        val upTime = downTime + (steps + 1) * stepDuration
        val upEvent = MotionEvent.obtain(
            downTime, upTime, MotionEvent.ACTION_UP, endX, endY, 0
        )
        target.dispatchTouchEvent(upEvent)
        upEvent.recycle()
    }

    private fun handleScroll(params: JSONObject): JSONObject {
        val direction = params.optString("direction", "down")
        val distance = params.optInt("distance", 300)
        val key = params.optString("key", "")

        val activity = currentActivity
            ?: return JSONObject().apply {
                put("success", false)
                put("message", "No active activity")
            }

        val success = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            val target = if (key.isNotEmpty()) {
                ViewTraversal.findByKey(root, key)
            } else {
                findFirstScrollable(root)
            }

            if (target == null) return@runOnMainThreadBlocking false

            when (target) {
                is ScrollView -> {
                    val dy = if (direction == "up") -distance else distance
                    target.smoothScrollBy(0, dy)
                    true
                }
                is HorizontalScrollView -> {
                    val dx = if (direction == "left") -distance else distance
                    target.smoothScrollBy(dx, 0)
                    true
                }
                else -> {
                    // Try generic scrollBy for RecyclerView or other scrollable views
                    try {
                        val dx = when (direction) {
                            "left" -> -distance; "right" -> distance; else -> 0
                        }
                        val dy = when (direction) {
                            "up" -> -distance; "down" -> distance; else -> 0
                        }
                        target.scrollBy(dx, dy)
                        true
                    } catch (_: Exception) {
                        false
                    }
                }
            }
        }

        return JSONObject().apply {
            put("success", success)
        }
    }

    private fun findFirstScrollable(view: View): View? {
        if (view is ScrollView || view is HorizontalScrollView) return view
        if (view.javaClass.simpleName.contains("RecyclerView")) return view
        if (view.canScrollVertically(1) || view.canScrollVertically(-1)) return view

        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                val found = findFirstScrollable(view.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
    }

    private fun handleFindElement(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val text = params.optString("text", "")
        val searchKey = key.ifEmpty { text }

        if (searchKey.isEmpty()) {
            return JSONObject().apply { put("found", false) }
        }

        val activity = currentActivity
            ?: return JSONObject().apply { put("found", false) }

        val result = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            val view = ViewTraversal.findByKey(root, searchKey)
            if (view != null) {
                Pair(true, ViewTraversal.describeView(view))
            } else {
                Pair(false, null)
            }
        }

        return JSONObject().apply {
            put("found", result.first)
            if (result.second != null) {
                put("element", mapToJsonObject(result.second!!))
            }
        }
    }

    private fun handleGetText(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        if (key.isEmpty()) {
            return JSONObject().apply { put("text", JSONObject.NULL) }
        }

        val activity = currentActivity
            ?: return JSONObject().apply { put("text", JSONObject.NULL) }

        val text = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            val view = ViewTraversal.findByKey(root, key)
            if (view != null) ViewTraversal.extractText(view) else null
        }

        return JSONObject().apply {
            put("text", text ?: JSONObject.NULL)
        }
    }

    private fun handleWaitForElement(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val text = params.optString("text", "")
        val searchKey = key.ifEmpty { text }

        if (searchKey.isEmpty()) {
            return JSONObject().apply { put("found", false) }
        }

        val activity = currentActivity
            ?: return JSONObject().apply { put("found", false) }

        val found = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            ViewTraversal.findByKey(root, searchKey) != null
        }

        return JSONObject().apply {
            put("found", found)
        }
    }

    private fun handleScreenshot(): JSONObject {
        val activity = currentActivity
            ?: return JSONObject().apply {
                put("success", false)
                put("message", "No active activity")
            }

        // Gather window and view dimensions on the main thread (fast, no blocking calls)
        data class ScreenshotParams(
            val window: android.view.Window,
            val width: Int,
            val height: Int
        )

        val params = runOnMainThreadBlocking {
            val rootView = activity.window.decorView.rootView
            ScreenshotParams(activity.window, rootView.width, rootView.height)
        }

        // Perform the actual capture on the IO thread to avoid deadlocking PixelCopy
        val base64 = captureScreenshot(activity, params.window, params.width, params.height)

        if (base64 == null) {
            return JSONObject().apply {
                put("success", false)
                put("message", "Screenshot capture failed")
            }
        }

        return JSONObject().apply {
            put("success", true)
            put("image", base64)
            put("format", "jpeg")
            put("encoding", "base64")
        }
    }

    @Suppress("DEPRECATION")
    private fun captureScreenshot(
        activity: Activity,
        window: android.view.Window,
        width: Int,
        height: Int
    ): String? {
        return try {
            // Use PixelCopy on API 26+ for hardware-accelerated capture
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                captureWithPixelCopy(window, width, height)
            } else {
                runOnMainThreadBlocking {
                    captureWithDrawingCache(activity.window.decorView.rootView)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Screenshot failed: ${e.message}")
            null
        }
    }

    private fun captureWithPixelCopy(
        window: android.view.Window,
        width: Int,
        height: Int
    ): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null

        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val latch = CountDownLatch(1)
        var success = false

        // Use a separate handler thread so the callback is not posted to the main thread,
        // which avoids deadlock when the caller is blocking the main thread.
        val handlerThread = android.os.HandlerThread("PixelCopyThread")
        handlerThread.start()
        val pixelCopyHandler = Handler(handlerThread.looper)

        android.view.PixelCopy.request(
            window,
            bitmap,
            { result ->
                success = (result == android.view.PixelCopy.SUCCESS)
                latch.countDown()
            },
            pixelCopyHandler
        )

        latch.await(5, TimeUnit.SECONDS)
        handlerThread.quitSafely()

        if (!success) {
            return runOnMainThreadBlocking {
                captureWithDrawingCache(window.decorView.rootView)
            }
        }

        return bitmapToBase64(bitmap)
    }

    @Suppress("DEPRECATION")
    private fun captureWithDrawingCache(view: View): String? {
        view.isDrawingCacheEnabled = true
        view.buildDrawingCache()
        val bitmap = view.drawingCache ?: return null
        val copy = bitmap.copy(Bitmap.Config.ARGB_8888, false)
        view.isDrawingCacheEnabled = false
        return bitmapToBase64(copy)
    }

    private fun bitmapToBase64(bitmap: Bitmap): String {
        // Scale down if too large (>720p) to keep WS payload manageable
        val scaledBitmap = if (bitmap.width > 720 || bitmap.height > 1280) {
            val scale = minOf(720f / bitmap.width, 1280f / bitmap.height)
            val w = (bitmap.width * scale).toInt()
            val h = (bitmap.height * scale).toInt()
            val scaled = Bitmap.createScaledBitmap(bitmap, w, h, true)
            bitmap.recycle()
            scaled
        } else {
            bitmap
        }

        val stream = ByteArrayOutputStream()
        // Use JPEG for much smaller payload (PNG is 10-20x larger)
        scaledBitmap.compress(Bitmap.CompressFormat.JPEG, 80, stream)
        scaledBitmap.recycle()
        return Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
    }

    private fun handleScreenshotRegion(params: JSONObject): JSONObject {
        val screenshotResult = handleScreenshot()
        if (!screenshotResult.optBoolean("success", false)) return screenshotResult

        val fullBase64 = screenshotResult.optString("image", "")
        if (fullBase64.isEmpty()) return screenshotResult

        val x = params.optInt("x", 0)
        val y = params.optInt("y", 0)
        val width = params.optInt("width", 300)
        val height = params.optInt("height", 300)

        return try {
            val bytes = Base64.decode(fullBase64, Base64.NO_WRAP)
            val fullBitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            // Clamp to bitmap bounds
            val cx = x.coerceIn(0, fullBitmap.width - 1)
            val cy = y.coerceIn(0, fullBitmap.height - 1)
            val cw = width.coerceAtMost(fullBitmap.width - cx)
            val ch = height.coerceAtMost(fullBitmap.height - cy)
            val cropped = Bitmap.createBitmap(fullBitmap, cx, cy, cw, ch)
            fullBitmap.recycle()
            val b64 = bitmapToBase64(cropped)
            JSONObject().apply {
                put("success", true)
                put("image", b64)
                put("format", "jpeg")
                put("encoding", "base64")
            }
        } catch (e: Exception) {
            JSONObject().apply {
                put("success", false)
                put("message", "Failed to crop screenshot: ${e.message}")
            }
        }
    }

    private fun handleScreenshotElement(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val refId = params.optString("ref", "")

        if (key.isEmpty() && refId.isEmpty()) {
            return JSONObject().apply { put("success", false); put("message", "Missing key or ref") }
        }

        val activity = currentActivity
            ?: return JSONObject().apply { put("success", false); put("message", "No active activity") }

        val bounds = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            var view: View? = null
            if (refId.isNotEmpty()) view = findViewByRefId(root, refId)
            if (view == null && key.isNotEmpty()) view = ViewTraversal.findByKey(root, key)
            if (view != null) {
                val location = IntArray(2)
                view.getLocationOnScreen(location)
                intArrayOf(location[0], location[1], view.width, view.height)
            } else null
        } ?: return JSONObject().apply { put("success", false); put("message", "Element not found") }

        val regionParams = JSONObject().apply {
            put("x", bounds[0])
            put("y", bounds[1])
            put("width", bounds[2])
            put("height", bounds[3])
        }
        return handleScreenshotRegion(regionParams)
    }

    private fun handleGetLogs(): JSONObject {
        val logsArray = JSONArray()
        for (entry in logBuffer) {
            logsArray.put(entry)
        }
        return JSONObject().apply {
            put("logs", logsArray)
        }
    }

    private fun handleClearLogs(): JSONObject {
        logBuffer.clear()
        return JSONObject().apply {
            put("success", true)
        }
    }

    @Suppress("DEPRECATION")
    private fun handleGoBack(): JSONObject {
        // Try currentActivity first, then fall back to any resumed activity
        val activity = currentActivity
            ?: application?.let { app ->
                // Try to find any resumed activity via the registered callbacks
                null // If currentActivity is null, we have no activity
            }
            ?: return JSONObject().apply {
                put("success", false)
                put("message", "No active activity — app may be in background")
            }

        runOnMainThreadBlocking {
            // onBackPressed is deprecated in API 33+ but still works
            // and delegates to OnBackPressedDispatcher internally.
            @Suppress("DEPRECATION")
            activity.onBackPressed()
        }

        return JSONObject().apply {
            put("success", true)
        }
    }

    private fun handlePressKey(params: JSONObject): JSONObject {
        val keyName = params.optString("key", "")
        if (keyName.isEmpty()) {
            return JSONObject().apply {
                put("success", false)
                put("error", "Missing key parameter")
            }
        }

        val modifiersArray = params.optJSONArray("modifiers")
        val modifiers = mutableListOf<String>()
        if (modifiersArray != null) {
            for (i in 0 until modifiersArray.length()) {
                modifiers.add(modifiersArray.getString(i).lowercase())
            }
        }

        val keyCodeMap = mapOf(
            "enter" to android.view.KeyEvent.KEYCODE_ENTER,
            "tab" to android.view.KeyEvent.KEYCODE_TAB,
            "escape" to android.view.KeyEvent.KEYCODE_ESCAPE,
            "backspace" to android.view.KeyEvent.KEYCODE_DEL,
            "delete" to android.view.KeyEvent.KEYCODE_FORWARD_DEL,
            "space" to android.view.KeyEvent.KEYCODE_SPACE,
            "up" to android.view.KeyEvent.KEYCODE_DPAD_UP,
            "down" to android.view.KeyEvent.KEYCODE_DPAD_DOWN,
            "left" to android.view.KeyEvent.KEYCODE_DPAD_LEFT,
            "right" to android.view.KeyEvent.KEYCODE_DPAD_RIGHT,
            "home" to android.view.KeyEvent.KEYCODE_MOVE_HOME,
            "end" to android.view.KeyEvent.KEYCODE_MOVE_END,
            "pageup" to android.view.KeyEvent.KEYCODE_PAGE_UP,
            "pagedown" to android.view.KeyEvent.KEYCODE_PAGE_DOWN,
        )

        // Map single characters to key codes
        val keyCode = keyCodeMap[keyName.lowercase()]
            ?: if (keyName.length == 1) {
                android.view.KeyEvent.keyCodeFromString("KEYCODE_${keyName.uppercase()}")
            } else {
                return JSONObject().apply {
                    put("success", false)
                    put("error", "Unknown key: $keyName")
                }
            }

        if (keyCode == android.view.KeyEvent.KEYCODE_UNKNOWN) {
            return JSONObject().apply {
                put("success", false)
                put("error", "Unknown key: $keyName")
            }
        }

        var metaState = 0
        if ("ctrl" in modifiers) metaState = metaState or android.view.KeyEvent.META_CTRL_ON
        if ("shift" in modifiers) metaState = metaState or android.view.KeyEvent.META_SHIFT_ON
        if ("alt" in modifiers) metaState = metaState or android.view.KeyEvent.META_ALT_ON
        if ("meta" in modifiers) metaState = metaState or android.view.KeyEvent.META_META_ON

        return try {
            val activity = currentActivity
                ?: return JSONObject().apply {
                    put("success", false)
                    put("error", "No active activity")
                }

            runOnMainThreadBlocking {
                val downTime = SystemClock.uptimeMillis()
                val downEvent = android.view.KeyEvent(
                    downTime, downTime, android.view.KeyEvent.ACTION_DOWN, keyCode, 0, metaState
                )
                val upEvent = android.view.KeyEvent(
                    downTime, SystemClock.uptimeMillis(), android.view.KeyEvent.ACTION_UP, keyCode, 0, metaState
                )
                activity.dispatchKeyEvent(downEvent)
                activity.dispatchKeyEvent(upEvent)
            }

            JSONObject().apply { put("success", true) }
        } catch (e: Exception) {
            JSONObject().apply {
                put("success", false)
                put("error", e.message ?: "Key press failed")
            }
        }
    }

    // ---------------------------------------------------------------
    // Additional bridge method implementations
    // ---------------------------------------------------------------

    private fun handleLongPress(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val refId = params.optString("ref", "")
        val duration = params.optLong("duration", 500L)

        val activity = currentActivity
            ?: return JSONObject().apply { put("success", false); put("message", "No active activity") }

        val success = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            var view: View? = null
            if (refId.isNotEmpty()) view = findViewByRefId(root, refId)
            if (view == null && key.isNotEmpty()) view = ViewTraversal.findByKey(root, key)
            if (view != null) {
                view.performLongClick()
                true
            } else false
        }
        return JSONObject().apply { put("success", success) }
    }

    private fun handleDoubleTap(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val refId = params.optString("ref", "")

        val activity = currentActivity
            ?: return JSONObject().apply { put("success", false); put("message", "No active activity") }

        val success = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            var view: View? = null
            if (refId.isNotEmpty()) view = findViewByRefId(root, refId)
            if (view == null && key.isNotEmpty()) view = ViewTraversal.findByKey(root, key)
            if (view != null) {
                view.performClick()
                view.performClick()
                true
            } else false
        }
        return JSONObject().apply { put("success", success) }
    }

    private fun handleDrag(params: JSONObject): JSONObject {
        val startX = params.optDouble("startX", 0.0).toFloat()
        val startY = params.optDouble("startY", 0.0).toFloat()
        val endX = params.optDouble("endX", 0.0).toFloat()
        val endY = params.optDouble("endY", 0.0).toFloat()

        val activity = currentActivity
            ?: return JSONObject().apply { put("success", false); put("message", "No active activity") }

        runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            dispatchSwipeGesture(root, startX, startY, endX, endY)
        }
        return JSONObject().apply { put("success", true) }
    }

    private fun handleTapAt(params: JSONObject): JSONObject {
        val x = params.optDouble("x", 0.0).toFloat()
        val y = params.optDouble("y", 0.0).toFloat()

        val activity = currentActivity
            ?: return JSONObject().apply { put("success", false); put("message", "No active activity") }

        runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            val downTime = SystemClock.uptimeMillis()
            val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0)
            val up = MotionEvent.obtain(downTime, downTime + 50, MotionEvent.ACTION_UP, x, y, 0)
            root.dispatchTouchEvent(down)
            root.dispatchTouchEvent(up)
            down.recycle()
            up.recycle()
        }
        return JSONObject().apply { put("success", true) }
    }

    private fun handleLongPressAt(params: JSONObject): JSONObject {
        val x = params.optDouble("x", 0.0).toFloat()
        val y = params.optDouble("y", 0.0).toFloat()
        val duration = params.optLong("duration", 500L)

        val activity = currentActivity
            ?: return JSONObject().apply { put("success", false); put("message", "No active activity") }

        runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            val downTime = SystemClock.uptimeMillis()
            val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0)
            root.dispatchTouchEvent(down)
            down.recycle()
        }
        Thread.sleep(duration)
        runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            val now = SystemClock.uptimeMillis()
            val up = MotionEvent.obtain(now, now, MotionEvent.ACTION_UP, x, y, 0)
            root.dispatchTouchEvent(up)
            up.recycle()
        }
        return JSONObject().apply { put("success", true) }
    }

    private fun handleEdgeSwipe(params: JSONObject): JSONObject {
        val edge = params.optString("edge", "left")
        val distance = params.optInt("distance", 200)

        val activity = currentActivity
            ?: return JSONObject().apply { put("success", false); put("message", "No active activity") }

        runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            val w = root.width.toFloat()
            val h = root.height.toFloat()
            val (sx, sy, ex, ey) = when (edge) {
                "left" -> listOf(0f, h / 2, distance.toFloat(), h / 2)
                "right" -> listOf(w, h / 2, w - distance, h / 2)
                "top" -> listOf(w / 2, 0f, w / 2, distance.toFloat())
                "bottom" -> listOf(w / 2, h, w / 2, h - distance)
                else -> listOf(0f, h / 2, distance.toFloat(), h / 2)
            }
            dispatchSwipeGesture(root, sx, sy, ex, ey)
        }
        return JSONObject().apply { put("success", true) }
    }

    private fun handleGesture(params: JSONObject): JSONObject {
        // Basic gesture support — execute tap/swipe actions sequentially
        val actions = params.optJSONArray("actions") ?: JSONArray()
        val activity = currentActivity
            ?: return JSONObject().apply { put("success", false); put("message", "No active activity") }

        for (i in 0 until actions.length()) {
            val action = actions.getJSONObject(i)
            when (action.optString("type")) {
                "tap" -> {
                    val x = action.optDouble("x", 0.0).toFloat()
                    val y = action.optDouble("y", 0.0).toFloat()
                    runOnMainThreadBlocking {
                        val root = activity.window.decorView.rootView
                        val downTime = SystemClock.uptimeMillis()
                        val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0)
                        val up = MotionEvent.obtain(downTime, downTime + 50, MotionEvent.ACTION_UP, x, y, 0)
                        root.dispatchTouchEvent(down)
                        root.dispatchTouchEvent(up)
                        down.recycle()
                        up.recycle()
                    }
                }
                "swipe" -> {
                    val sx = action.optDouble("startX", action.optDouble("x", 0.0)).toFloat()
                    val sy = action.optDouble("startY", action.optDouble("y", 0.0)).toFloat()
                    val ex = action.optDouble("endX", 0.0).toFloat()
                    val ey = action.optDouble("endY", 0.0).toFloat()
                    runOnMainThreadBlocking {
                        dispatchSwipeGesture(activity.window.decorView.rootView, sx, sy, ex, ey)
                    }
                }
                "wait" -> {
                    val ms = action.optLong("duration", action.optLong("ms", 500))
                    Thread.sleep(ms)
                }
            }
        }
        return JSONObject().apply { put("success", true) }
    }

    private fun handleScrollUntilVisible(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val text = params.optString("text", "")
        val direction = params.optString("direction", "down")
        val maxScrolls = params.optInt("maxScrolls", 10)
        val searchKey = key.ifEmpty { text }

        val activity = currentActivity
            ?: return JSONObject().apply { put("success", false) }

        for (i in 0 until maxScrolls) {
            val found = runOnMainThreadBlocking {
                val root = activity.window.decorView.rootView
                ViewTraversal.findByKey(root, searchKey) != null
            }
            if (found) return JSONObject().apply { put("success", true) }

            // Scroll
            runOnMainThreadBlocking {
                val root = activity.window.decorView.rootView
                val scrollable = findFirstScrollable(root)
                if (scrollable != null) {
                    val dist = 300
                    when (scrollable) {
                        is ScrollView -> scrollable.smoothScrollBy(0, if (direction == "up") -dist else dist)
                        is HorizontalScrollView -> scrollable.smoothScrollBy(if (direction == "left") -dist else dist, 0)
                        else -> scrollable.scrollBy(0, if (direction == "up") -dist else dist)
                    }
                }
            }
            Thread.sleep(200)
        }
        return JSONObject().apply { put("success", false) }
    }

    private fun handleSwipeCoordinates(params: JSONObject): JSONObject {
        val startX = params.optDouble("startX", 0.0).toFloat()
        val startY = params.optDouble("startY", 0.0).toFloat()
        val endX = params.optDouble("endX", 0.0).toFloat()
        val endY = params.optDouble("endY", 0.0).toFloat()

        val activity = currentActivity
            ?: return JSONObject().apply { put("success", false) }

        runOnMainThreadBlocking {
            dispatchSwipeGesture(activity.window.decorView.rootView, startX, startY, endX, endY)
        }
        return JSONObject().apply { put("success", true) }
    }

    private fun handleGetCheckboxState(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val activity = currentActivity
            ?: return JSONObject().apply { put("checked", false) }

        val checked = runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            val view = ViewTraversal.findByKey(root, key)
            when (view) {
                is android.widget.CheckBox -> view.isChecked
                is android.widget.Switch -> view.isChecked
                is android.widget.ToggleButton -> view.isChecked
                is android.widget.CompoundButton -> view.isChecked
                else -> false
            }
        }
        return JSONObject().apply { put("checked", checked) }
    }

    private fun handleGetSliderValue(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val activity = currentActivity
            ?: return JSONObject().apply { put("value", 0); put("min", 0); put("max", 100) }

        return runOnMainThreadBlocking {
            val root = activity.window.decorView.rootView
            val view = ViewTraversal.findByKey(root, key)
            if (view is android.widget.SeekBar) {
                JSONObject().apply {
                    put("value", view.progress)
                    put("min", if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) view.min else 0)
                    put("max", view.max)
                }
            } else {
                JSONObject().apply { put("value", 0); put("min", 0); put("max", 100) }
            }
        }
    }

    private fun handleGetRoute(): JSONObject {
        val activity = currentActivity
        val name = activity?.javaClass?.simpleName ?: "unknown"
        return JSONObject().apply { put("route", name) }
    }

    private fun handleGetNavigationStack(): JSONObject {
        val activity = currentActivity
        val name = activity?.javaClass?.simpleName ?: "unknown"
        return JSONObject().apply {
            put("stack", JSONArray().put(name))
            put("length", 1)
        }
    }

    private fun handleGetErrors(): JSONObject {
        return JSONObject().apply { put("errors", JSONArray()) }
    }

    private fun handleGetPerformance(): JSONObject {
        return JSONObject().apply { put("fps", 60); put("frameTime", 16.6) }
    }

    private fun handleGetFrameStats(): JSONObject {
        return JSONObject().apply { put("now", System.currentTimeMillis()) }
    }

    private fun handleGetMemoryStats(): JSONObject {
        val runtime = Runtime.getRuntime()
        return JSONObject().apply {
            put("usedMemory", runtime.totalMemory() - runtime.freeMemory())
            put("totalMemory", runtime.totalMemory())
            put("maxMemory", runtime.maxMemory())
        }
    }

    private fun handleWaitForGone(params: JSONObject): JSONObject {
        val key = params.optString("key", "")
        val text = params.optString("text", "")
        val timeout = params.optLong("timeout", 5000L)
        val searchKey = key.ifEmpty { text }

        if (searchKey.isEmpty()) return JSONObject().apply { put("success", true) }

        val activity = currentActivity
            ?: return JSONObject().apply { put("success", true) }

        val start = System.currentTimeMillis()
        while (System.currentTimeMillis() - start < timeout) {
            val found = runOnMainThreadBlocking {
                val root = activity.window.decorView.rootView
                ViewTraversal.findByKey(root, searchKey) != null
            }
            if (!found) return JSONObject().apply { put("success", true) }
            Thread.sleep(200)
        }
        return JSONObject().apply { put("success", false) }
    }

    private fun handleDiagnose(): JSONObject {
        val activity = currentActivity
        return JSONObject().apply {
            put("platform", "android")
            put("framework", "android-native")
            put("os_version", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            put("app_name", appName)
            if (activity != null) {
                put("activity", activity.javaClass.simpleName)
            }
        }
    }

    private fun handleEnableTestIndicators(): JSONObject {
        return JSONObject().apply { put("success", true) }
    }

    private fun handleGetIndicatorStatus(): JSONObject {
        return JSONObject().apply { put("enabled", false) }
    }

    private fun handleEnableNetworkMonitoring(): JSONObject {
        return JSONObject().apply { put("success", true) }
    }

    private fun handleGetNetworkRequests(): JSONObject {
        return JSONObject().apply { put("requests", JSONArray()) }
    }

    private fun handleClearNetworkRequests(): JSONObject {
        return JSONObject().apply { put("success", true) }
    }

    // ---------------------------------------------------------------
    // Ref ID resolution utilities
    // ---------------------------------------------------------------

    /**
     * Find a view by ref ID from the structured inspect data
     */
    private fun findViewByRefId(root: View, targetRefId: String): View? {
        val result = ViewTraversal.collectInteractiveElementsStructured(root)
        val elements = result.first
        
        // Find the element with matching ref ID and get its bounds
        val targetElement = elements.find { it["ref"] == targetRefId } ?: return null
        val bounds = targetElement["bounds"] as? Map<String, Any?> ?: return null
        
        val x = (bounds["x"] as? Int) ?: return null
        val y = (bounds["y"] as? Int) ?: return null
        val w = (bounds["w"] as? Int) ?: return null
        val h = (bounds["h"] as? Int) ?: return null
        
        if (w <= 0 || h <= 0) return null
        
        val centerX = x + w / 2
        val centerY = y + h / 2
        
        // Find the view at the center position
        return findViewAtPosition(root, centerX, centerY)
    }

    /**
     * Find view at a specific screen position
     */
    private fun findViewAtPosition(root: View, targetX: Int, targetY: Int): View? {
        fun checkView(view: View): View? {
            if (view.visibility != View.VISIBLE) return null
            
            val location = IntArray(2)
            view.getLocationOnScreen(location)
            val left = location[0]
            val top = location[1]
            val right = left + view.width
            val bottom = top + view.height
            
            if (targetX in left..right && targetY in top..bottom) {
                // Check children first (they're on top)
                if (view is ViewGroup) {
                    for (i in view.childCount - 1 downTo 0) {
                        val child = view.getChildAt(i)
                        val found = checkView(child)
                        if (found != null) return found
                    }
                }
                
                // Return this view if it's interactive
                if (ViewTraversal.isInteractiveView(view)) {
                    return view
                }
            }
            
            return null
        }
        
        return checkView(root)
    }

    // ---------------------------------------------------------------
    // Utilities
    // ---------------------------------------------------------------

    /**
     * Execute a block on the main thread and block until it completes.
     * Used to safely access View hierarchy from the server IO thread.
     */
    private fun <T> runOnMainThreadBlocking(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return block()
        }

        val latch = CountDownLatch(1)
        var result: T? = null
        var error: Throwable? = null

        mainHandler.post {
            try {
                result = block()
            } catch (e: Throwable) {
                error = e
            } finally {
                latch.countDown()
            }
        }

        latch.await(10, TimeUnit.SECONDS)

        error?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return result as T
    }

    /**
     * Convert a Map<String, Any?> to a JSONObject, handling nested maps.
     */
    private fun mapToJsonObject(map: Map<String, Any?>): JSONObject {
        val json = JSONObject()
        for ((key, value) in map) {
            when (value) {
                null -> json.put(key, JSONObject.NULL)
                is Map<*, *> -> {
                    @Suppress("UNCHECKED_CAST")
                    json.put(key, mapToJsonObject(value as Map<String, Any?>))
                }
                is List<*> -> json.put(key, JSONArray(value))
                is Boolean -> json.put(key, value)
                is Int -> json.put(key, value)
                is Long -> json.put(key, value)
                is Double -> json.put(key, value)
                is Float -> json.put(key, value.toDouble())
                else -> json.put(key, value.toString())
            }
        }
        return json
    }
}
