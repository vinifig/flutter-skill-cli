package com.flutterskill

import android.app.Activity
import android.graphics.Bitmap
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.ScrollView
import android.widget.TextView
import kotlinx.serialization.json.*
import java.io.ByteArrayOutputStream
import java.lang.ref.WeakReference

class AndroidBridge(activity: Activity) : PlatformBridge {
    private val activityRef = WeakReference(activity)
    private val activity get() = activityRef.get() ?: throw IllegalStateException("Activity gone")

    override suspend fun inspectInteractive(): JsonElement {
        val root = activity.window.decorView.rootView
        val elements = mutableListOf<JsonElement>()
        val refCounts = mutableMapOf<String, Int>()

        fun generateSemanticRef(role: String, content: String?, refCounts: MutableMap<String, Int>): String {
            // Clean content: spaces to underscores, remove special chars, truncate to 30 chars
            val sanitized = content?.trim()
                ?.replace(Regex("\\s+"), "_")
                ?.replace(Regex("[^\\w]"), "")
                ?.take(30)
                ?.takeIf { it.isNotEmpty() }

            val base = if (sanitized != null) "${role}:${sanitized}" else role
            val count = refCounts[base] ?: 0
            refCounts[base] = count + 1

            return if (count == 0) base else "${base}[${count}]"
        }

        fun getElementType(view: View): String = when (view) {
            is android.widget.Button -> "button"
            is EditText -> "input"
            is android.widget.CheckBox -> "toggle"
            is android.widget.Switch -> "toggle"
            is android.widget.SeekBar -> "slider"
            is android.widget.Spinner -> "select"
            else -> if (view.isClickable) "button" else "element"
        }

        fun extractContent(view: View): String? {
            return view.contentDescription?.toString()
                ?: (view as? TextView)?.text?.toString()
                ?: try { if (view.id != View.NO_ID) view.resources.getResourceEntryName(view.id) else null } catch (_: Exception) { null }
        }

        fun getActions(elementType: String): List<String> = when (elementType) {
            "input" -> listOf("tap", "enter_text")
            "slider" -> listOf("tap", "swipe")
            else -> listOf("tap")
        }

        fun getValue(view: View, elementType: String): Any? = when (elementType) {
            "input" -> (view as? EditText)?.text?.toString() ?: ""
            "toggle" -> when (view) {
                is android.widget.CheckBox -> view.isChecked
                is android.widget.Switch -> view.isChecked
                else -> false
            }
            "slider" -> (view as? android.widget.SeekBar)?.progress ?: 0
            else -> null
        }

        fun walkInteractive(view: View) {
            val isInteractive = view.isClickable || view is EditText || view is android.widget.SeekBar

            if (isInteractive) {
                val elementType = getElementType(view)
                val role = elementType
                val content = extractContent(view)
                val refId = generateSemanticRef(role, content, refCounts)

                val location = IntArray(2)
                view.getLocationOnScreen(location)

                val element = buildJsonObject {
                    put("ref", refId)
                    put("type", view.javaClass.simpleName)
                    put("actions", JsonArray(getActions(elementType).map { JsonPrimitive(it) }))
                    put("enabled", view.isEnabled)
                    put("bounds", buildJsonObject {
                        put("x", location[0])
                        put("y", location[1])
                        put("w", view.width)
                        put("h", view.height)
                    })

                    // Optional fields
                    val text = extractContent(view)
                    if (!text.isNullOrEmpty()) {
                        put("text", text)
                    }

                    val value = getValue(view, elementType)
                    if (value != null) {
                        put("value", when (value) {
                            is String -> JsonPrimitive(value)
                            is Boolean -> JsonPrimitive(value)
                            is Int -> JsonPrimitive(value)
                            else -> JsonPrimitive(value.toString())
                        })
                    }
                }

                elements.add(element)
            }

            if (view is ViewGroup) {
                for (i in 0 until view.childCount) {
                    walkInteractive(view.getChildAt(i))
                }
            }
        }

        walkInteractive(root)

        // Generate summary
        val counts = refCounts.entries.map { (_, count) -> count }.sum()
        val summary = if (counts == 0) {
            "No interactive elements found"
        } else {
            "$counts interactive elements found"
        }

        return buildJsonObject {
            put("elements", JsonArray(elements))
            put("summary", summary)
        }
    }

    override suspend fun tapRef(refId: String): JsonElement {
        // Re-generate interactive data to find element by ref
        val interactiveData = inspectInteractive().jsonObject
        val elements = interactiveData["elements"]?.jsonArray ?: return buildJsonObject { put("error", "no elements") }
        
        val targetElement = elements.find { 
            it.jsonObject["ref"]?.jsonPrimitive?.content == refId 
        }?.jsonObject ?: return buildJsonObject { put("error", "ref not found") }

        val bounds = targetElement["bounds"]?.jsonObject
        val x = bounds?.get("x")?.jsonPrimitive?.int ?: return buildJsonObject { put("error", "no bounds") }
        val y = bounds["y"]?.jsonPrimitive?.int ?: return buildJsonObject { put("error", "no bounds") }
        val w = bounds["w"]?.jsonPrimitive?.int ?: return buildJsonObject { put("error", "no bounds") }
        val h = bounds["h"]?.jsonPrimitive?.int ?: return buildJsonObject { put("error", "no bounds") }

        // Find view at center position
        val centerX = x + w / 2
        val centerY = y + h / 2
        val root = activity.window.decorView.rootView
        val view = root.findViewAt(centerX, centerY)

        if (view != null) {
            activity.runOnUiThread { view.performClick() }
            return buildJsonObject { put("tapped", true) }
        }

        return buildJsonObject { put("error", "view not found at position") }
    }

    override suspend fun enterTextRef(refId: String, text: String): JsonElement {
        // Re-generate interactive data to find element by ref
        val interactiveData = inspectInteractive().jsonObject
        val elements = interactiveData["elements"]?.jsonArray ?: return buildJsonObject { put("error", "no elements") }
        
        val targetElement = elements.find { 
            it.jsonObject["ref"]?.jsonPrimitive?.content == refId 
        }?.jsonObject ?: return buildJsonObject { put("error", "ref not found") }

        val bounds = targetElement["bounds"]?.jsonObject
        val x = bounds?.get("x")?.jsonPrimitive?.int ?: return buildJsonObject { put("error", "no bounds") }
        val y = bounds["y"]?.jsonPrimitive?.int ?: return buildJsonObject { put("error", "no bounds") }
        val w = bounds["w"]?.jsonPrimitive?.int ?: return buildJsonObject { put("error", "no bounds") }
        val h = bounds["h"]?.jsonPrimitive?.int ?: return buildJsonObject { put("error", "no bounds") }

        // Find view at center position
        val centerX = x + w / 2
        val centerY = y + h / 2
        val root = activity.window.decorView.rootView
        val view = root.findViewAt(centerX, centerY) as? EditText
            ?: return buildJsonObject { put("error", "not an EditText") }

        activity.runOnUiThread { view.setText(text) }
        return buildJsonObject { put("entered", true) }
    }

    private fun View.findViewAt(x: Int, y: Int): View? {
        val location = IntArray(2)
        this.getLocationOnScreen(location)
        val viewX = location[0]
        val viewY = location[1]
        val viewRight = viewX + this.width
        val viewBottom = viewY + this.height

        // Check if point is within this view's bounds
        if (x >= viewX && x <= viewRight && y >= viewY && y <= viewBottom) {
            // Check children first (depth-first search)
            if (this is ViewGroup) {
                for (i in 0 until this.childCount) {
                    val child = this.getChildAt(i)
                    val found = child.findViewAt(x, y)
                    if (found != null) return found
                }
            }
            // If no child contains the point, this view is the deepest match
            return this
        }
        return null
    }

    override suspend fun inspect(): JsonElement {
        val root = activity.window.decorView.rootView
        return walkView(root, 0)
    }

    private fun walkView(view: View, depth: Int): JsonElement = buildJsonObject {
        put("class", view.javaClass.simpleName)
        view.contentDescription?.let { put("contentDescription", it.toString()) }
        if (view.id != View.NO_ID) {
            try { put("id", view.resources.getResourceEntryName(view.id)) } catch (_: Exception) {}
        }
        if (view is TextView) put("text", view.text.toString().take(200))
        if (view is ViewGroup && depth < 15) {
            put("children", buildJsonArray {
                for (i in 0 until view.childCount) add(walkView(view.getChildAt(i), depth + 1))
            })
        }
    }

    override suspend fun tap(selector: String): JsonElement {
        val view = findViewBySelector(selector) ?: return buildJsonObject { put("error", "not found") }
        activity.runOnUiThread { view.performClick() }
        return buildJsonObject { put("tapped", true) }
    }

    override suspend fun enterText(selector: String, text: String): JsonElement {
        val view = findViewBySelector(selector) as? EditText
            ?: return buildJsonObject { put("error", "EditText not found") }
        activity.runOnUiThread { view.setText(text) }
        return buildJsonObject { put("entered", true) }
    }

    override suspend fun screenshot(): JsonElement {
        val root = activity.window.decorView.rootView
        root.isDrawingCacheEnabled = true
        val bitmap = Bitmap.createBitmap(root.drawingCache)
        root.isDrawingCacheEnabled = false
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 90, stream)
        val b64 = Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
        return buildJsonObject { put("screenshot", b64); put("format", "png") }
    }

    override suspend fun scroll(dx: Int, dy: Int): JsonElement {
        val root = activity.window.decorView
        val scrollView = findFirst(root) { it is ScrollView } as? ScrollView
        scrollView?.let { activity.runOnUiThread { it.scrollBy(dx, dy) } }
        return buildJsonObject { put("scrolled", scrollView != null) }
    }

    override suspend fun getText(selector: String): JsonElement {
        val view = findViewBySelector(selector) as? TextView
            ?: return buildJsonObject { put("error", "not found") }
        return buildJsonObject { put("text", view.text.toString()) }
    }

    override suspend fun findElement(selector: String?, text: String?): JsonElement {
        if (selector != null) {
            val v = findViewBySelector(selector)
            return buildJsonObject { put("found", v != null) }
        }
        if (text != null) {
            val root = activity.window.decorView.rootView
            val v = findFirst(root) { it is TextView && it.text.toString().contains(text) }
            return buildJsonObject { put("found", v != null) }
        }
        return buildJsonObject { put("error", "selector or text required") }
    }

    override suspend fun waitForElement(selector: String, timeout: Long): JsonElement {
        val start = System.currentTimeMillis()
        while (System.currentTimeMillis() - start < timeout) {
            if (findViewBySelector(selector) != null) return buildJsonObject { put("found", true) }
            kotlinx.coroutines.delay(100)
        }
        return buildJsonObject { put("found", false); put("error", "timeout") }
    }

    override suspend fun goBack(): JsonElement {
        activity.runOnUiThread { activity.onBackPressed() }
        return buildJsonObject { put("success", true) }
    }

    private fun findViewBySelector(selector: String): View? {
        val root = activity.window.decorView.rootView
        // Try resource id match
        return findFirst(root) {
            try { it.id != View.NO_ID && it.resources.getResourceEntryName(it.id) == selector } catch (_: Exception) { false }
        } ?: findFirst(root) {
            it.contentDescription?.toString() == selector
        }
    }

    private fun findFirst(view: View, predicate: (View) -> Boolean): View? {
        if (predicate(view)) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findFirst(view.getChildAt(i), predicate)?.let { return it }
            }
        }
        return null
    }
}
