package com.flutterskill

import io.ktor.server.application.*
import io.ktor.server.cio.*
import io.ktor.server.engine.*
import io.ktor.server.routing.*
import io.ktor.server.websocket.*
import io.ktor.websocket.*
import kotlinx.coroutines.*
import kotlinx.serialization.*
import kotlinx.serialization.json.*

@Serializable
data class JsonRpcRequest(
    val jsonrpc: String = "2.0",
    val method: String,
    val params: JsonObject? = null,
    val id: JsonElement
)

@Serializable
data class JsonRpcResponse(
    val jsonrpc: String = "2.0",
    val result: JsonElement? = null,
    val error: JsonElement? = null,
    val id: JsonElement
)

interface PlatformBridge {
    suspend fun inspect(): JsonElement
    suspend fun inspectInteractive(): JsonElement
    suspend fun tap(selector: String): JsonElement
    suspend fun tapRef(refId: String): JsonElement
    suspend fun enterText(selector: String, text: String): JsonElement
    suspend fun enterTextRef(refId: String, text: String): JsonElement
    suspend fun screenshot(): JsonElement
    suspend fun scroll(dx: Int, dy: Int): JsonElement
    suspend fun getText(selector: String): JsonElement
    suspend fun findElement(selector: String?, text: String?): JsonElement
    suspend fun waitForElement(selector: String, timeout: Long): JsonElement
    suspend fun goBack(): JsonElement
}

class FlutterSkillBridge(
    private val platformBridge: PlatformBridge,
    private val port: Int = 18118
) {
    private var server: ApplicationEngine? = null
    private val json = Json { ignoreUnknownKeys = true }

    fun start() {
        server = embeddedServer(CIO, port = port) {
            install(WebSockets)
            routing {
                webSocket("/") {
                    for (frame in incoming) {
                        if (frame is Frame.Text) {
                            val text = frame.readText()
                            val response = handleRequest(text)
                            send(Frame.Text(response))
                        }
                    }
                }
            }
        }.start(wait = false)
        println("[flutter-skill-kmp] WebSocket server on port $port")
    }

    fun stop() {
        server?.stop(1000, 2000)
    }

    private suspend fun handleRequest(raw: String): String {
        val req = try {
            json.decodeFromString<JsonRpcRequest>(raw)
        } catch (e: Exception) {
            return json.encodeToString(JsonRpcResponse(
                error = buildJsonObject { put("code", -32700); put("message", "Parse error") },
                id = JsonNull
            ))
        }

        val params = req.params ?: buildJsonObject { }

        val result = try {
            when (req.method) {
                "health" -> buildJsonObject { put("status", "ok"); put("platform", "kmp") }
                "inspect" -> platformBridge.inspect()
                "inspect_interactive" -> platformBridge.inspectInteractive()
                "tap" -> {
                    val refId = params["ref"]?.jsonPrimitive?.contentOrNull
                    if (refId != null) {
                        platformBridge.tapRef(refId)
                    } else {
                        platformBridge.tap(params["selector"]?.jsonPrimitive?.content ?: "")
                    }
                }
                "enter_text" -> {
                    val refId = params["ref"]?.jsonPrimitive?.contentOrNull
                    val text = params["text"]?.jsonPrimitive?.content ?: ""
                    if (refId != null) {
                        platformBridge.enterTextRef(refId, text)
                    } else {
                        platformBridge.enterText(params["selector"]?.jsonPrimitive?.content ?: "", text)
                    }
                }
                "screenshot" -> platformBridge.screenshot()
                "scroll" -> platformBridge.scroll(
                    params["dx"]?.jsonPrimitive?.int ?: 0,
                    params["dy"]?.jsonPrimitive?.int ?: 0
                )
                "get_text" -> platformBridge.getText(params["selector"]?.jsonPrimitive?.content ?: "")
                "find_element" -> platformBridge.findElement(
                    params["selector"]?.jsonPrimitive?.contentOrNull,
                    params["text"]?.jsonPrimitive?.contentOrNull
                )
                "wait_for_element" -> platformBridge.waitForElement(
                    params["selector"]?.jsonPrimitive?.content ?: "",
                    params["timeout"]?.jsonPrimitive?.long ?: 5000L
                )
                "go_back" -> platformBridge.goBack()
                else -> {
                    return json.encodeToString(JsonRpcResponse(
                        error = buildJsonObject { put("code", -32601); put("message", "Method not found: ${req.method}") },
                        id = req.id
                    ))
                }
            }
        } catch (e: Exception) {
            return json.encodeToString(JsonRpcResponse(
                error = buildJsonObject { put("code", -32000); put("message", e.message ?: "error") },
                id = req.id
            ))
        }

        return json.encodeToString(JsonRpcResponse(result = result, id = req.id))
    }
}
