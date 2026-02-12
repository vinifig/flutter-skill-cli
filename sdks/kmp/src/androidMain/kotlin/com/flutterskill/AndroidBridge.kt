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
