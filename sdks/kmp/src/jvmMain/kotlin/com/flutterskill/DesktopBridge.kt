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

    override suspend fun inspectInteractive(): JsonElement {
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

        fun getElementType(comp: Component): String = when (comp) {
            is JButton -> "button"
            is JTextField -> "input"
            is JCheckBox -> "toggle"
            is JSlider -> "slider"
            is JComboBox<*> -> "select"
            else -> "element"
        }

        fun extractContent(comp: Component): String? = when (comp) {
            is JLabel -> comp.text
            is JButton -> comp.text
            is JTextField -> comp.text ?: comp.name
            is JCheckBox -> comp.text
            else -> comp.name
        }

        fun getActions(elementType: String): List<String> = when (elementType) {
            "input" -> listOf("tap", "enter_text")
            "slider" -> listOf("tap", "swipe")
            else -> listOf("tap")
        }

        fun getValue(comp: Component, elementType: String): Any? = when (elementType) {
            "input" -> (comp as? JTextField)?.text ?: ""
            "toggle" -> (comp as? JCheckBox)?.isSelected ?: false
            "slider" -> (comp as? JSlider)?.value ?: 0
            else -> null
        }

        fun walkInteractive(comp: Component) {
            val isInteractive = comp is JButton || comp is JTextField || 
                               comp is JCheckBox || comp is JSlider || comp is JComboBox<*>

            if (isInteractive) {
                val elementType = getElementType(comp)
                val role = elementType
                val content = extractContent(comp)
                val refId = generateSemanticRef(role, content, refCounts)

                val element = buildJsonObject {
                    put("ref", refId)
                    put("type", comp.javaClass.simpleName)
                    put("actions", JsonArray(getActions(elementType).map { JsonPrimitive(it) }))
                    put("enabled", comp.isEnabled)
                    put("bounds", buildJsonObject {
                        put("x", comp.x)
                        put("y", comp.y)
                        put("w", comp.width)
                        put("h", comp.height)
                    })

                    // Optional fields
                    val text = extractContent(comp)
                    if (!text.isNullOrEmpty()) {
                        put("text", text)
                    }

                    val value = getValue(comp, elementType)
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

            if (comp is Container) {
                for (child in comp.components) {
                    walkInteractive(child)
                }
            }
        }

        walkInteractive(getRoot())

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

        // Find component at center position
        val centerX = x + w / 2
        val centerY = y + h / 2
        val root = getRoot()
        val comp = root.findComponentAt(centerX, centerY)

        if (comp is AbstractButton) {
            SwingUtilities.invokeLater { comp.doClick() }
        } else if (comp != null) {
            val robot = Robot()
            robot.mouseMove(centerX, centerY)
            robot.mousePress(InputEvent.BUTTON1_DOWN_MASK)
            robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK)
        }

        return buildJsonObject { put("tapped", true) }
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

        // Find component at center position
        val centerX = x + w / 2
        val centerY = y + h / 2
        val root = getRoot()
        val comp = root.findComponentAt(centerX, centerY) as? JTextField
            ?: return buildJsonObject { put("error", "not a text field") }

        SwingUtilities.invokeLater { comp.text = text }
        return buildJsonObject { put("entered", true) }
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

    override suspend fun goBack(): JsonElement {
        // Desktop apps don't have a native back navigation concept.
        // Return success as a no-op rather than destroying any window.
        return buildJsonObject { put("success", true) }
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
