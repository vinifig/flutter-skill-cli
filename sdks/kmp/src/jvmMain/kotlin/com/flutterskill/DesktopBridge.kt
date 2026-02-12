package com.flutterskill

import kotlinx.serialization.json.*
import java.awt.*
import java.awt.event.InputEvent
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.util.Base64
import javax.imageio.ImageIO
import javax.swing.*

class DesktopBridge(private val rootFrame: Frame? = null) : PlatformBridge {

    private fun getRoot(): Container {
        return rootFrame ?: Frame.getFrames().firstOrNull() ?: throw IllegalStateException("No AWT Frame")
    }

    override suspend fun inspect(): JsonElement {
        return walkComponent(getRoot(), 0)
    }

    private fun walkComponent(comp: Component, depth: Int): JsonElement = buildJsonObject {
        put("class", comp.javaClass.simpleName)
        put("name", comp.name ?: "")
        put("bounds", "${comp.x},${comp.y},${comp.width},${comp.height}")
        if (comp is JLabel) put("text", comp.text?.take(200) ?: "")
        if (comp is JTextField) put("text", comp.text?.take(200) ?: "")
        if (comp is JButton) put("text", comp.text?.take(200) ?: "")
        if (comp is Container && depth < 15) {
            put("children", buildJsonArray {
                for (child in comp.components) add(walkComponent(child, depth + 1))
            })
        }
    }

    override suspend fun tap(selector: String): JsonElement {
        val comp = findByName(getRoot(), selector)
            ?: return buildJsonObject { put("error", "not found") }
        if (comp is AbstractButton) {
            SwingUtilities.invokeLater { comp.doClick() }
        } else {
            val loc = comp.locationOnScreen
            val robot = Robot()
            robot.mouseMove(loc.x + comp.width / 2, loc.y + comp.height / 2)
            robot.mousePress(InputEvent.BUTTON1_DOWN_MASK)
            robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK)
        }
        return buildJsonObject { put("tapped", true) }
    }

    override suspend fun enterText(selector: String, text: String): JsonElement {
        val comp = findByName(getRoot(), selector) as? JTextField
            ?: return buildJsonObject { put("error", "JTextField not found") }
        SwingUtilities.invokeLater { comp.text = text }
        return buildJsonObject { put("entered", true) }
    }

    override suspend fun screenshot(): JsonElement {
        val root = getRoot()
        val img = BufferedImage(root.width, root.height, BufferedImage.TYPE_INT_ARGB)
        SwingUtilities.invokeAndWait { root.paint(img.graphics) }
        val baos = ByteArrayOutputStream()
        ImageIO.write(img, "png", baos)
        val b64 = Base64.getEncoder().encodeToString(baos.toByteArray())
        return buildJsonObject { put("screenshot", b64); put("format", "png") }
    }

    override suspend fun scroll(dx: Int, dy: Int): JsonElement {
        val robot = Robot()
        if (dy != 0) robot.mouseWheel(dy / 40)
        return buildJsonObject { put("scrolled", true) }
    }

    override suspend fun getText(selector: String): JsonElement {
        val comp = findByName(getRoot(), selector)
        val text = when (comp) {
            is JLabel -> comp.text
            is JTextField -> comp.text
            is JButton -> comp.text
            else -> return buildJsonObject { put("error", "not found or no text") }
        }
        return buildJsonObject { put("text", text ?: "") }
    }

    override suspend fun findElement(selector: String?, text: String?): JsonElement {
        val root = getRoot()
        if (selector != null) {
            return buildJsonObject { put("found", findByName(root, selector) != null) }
        }
        if (text != null) {
            val found = findFirst(root) {
                (it is JLabel && it.text?.contains(text) == true) ||
                (it is JButton && it.text?.contains(text) == true)
            }
            return buildJsonObject { put("found", found != null) }
        }
        return buildJsonObject { put("error", "selector or text required") }
    }

    override suspend fun waitForElement(selector: String, timeout: Long): JsonElement {
        val start = System.currentTimeMillis()
        while (System.currentTimeMillis() - start < timeout) {
            if (findByName(getRoot(), selector) != null) return buildJsonObject { put("found", true) }
            kotlinx.coroutines.delay(100)
        }
        return buildJsonObject { put("found", false); put("error", "timeout") }
    }

    private fun findByName(comp: Component, name: String): Component? {
        if (comp.name == name) return comp
        if (comp is Container) {
            for (child in comp.components) {
                findByName(child, name)?.let { return it }
            }
        }
        return null
    }

    private fun findFirst(comp: Component, predicate: (Component) -> Boolean): Component? {
        if (predicate(comp)) return comp
        if (comp is Container) {
            for (child in comp.components) {
                findFirst(child, predicate)?.let { return it }
            }
        }
        return null
    }
}
