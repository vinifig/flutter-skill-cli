package com.aidashboad.flutterskill.ui

import com.intellij.ui.JBColor
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import java.awt.Color
import javax.swing.UIManager

/**
 * Theme-aware color system for Flutter Skill plugin
 * Maps semantic colors to IntelliJ theme colors
 */
object FlutterSkillColors {
    /**
     * Primary action color
     */
    val primary: Color
        get() = JBUI.CurrentTheme.ActionButton.pressedBackground()

    /**
     * Success state color (green)
     */
    val success: Color
        get() = JBColor(Color(0, 150, 0), Color(0, 200, 0))

    /**
     * Warning state color (yellow/orange)
     */
    val warning: Color
        get() = JBColor(Color(200, 140, 0), Color(255, 180, 0))

    /**
     * Error state color (red)
     */
    val error: Color
        get() = JBColor(Color(200, 0, 0), Color(255, 80, 80))

    /**
     * Border color
     */
    val border: Color
        get() = JBUI.CurrentTheme.CustomFrameDecorations.separatorForeground()

    /**
     * Background level 1 (panel background)
     */
    val bg1: Color
        get() = UIUtil.getPanelBackground()

    /**
     * Background level 2 (section header background)
     */
    val bg2: Color
        get() = JBUI.CurrentTheme.CustomFrameDecorations.paneBackground()

    /**
     * Text color (primary)
     */
    val text: Color
        get() = UIUtil.getLabelForeground()

    /**
     * Text color (secondary/muted)
     */
    val textSecondary: Color
        get() = UIUtil.getLabelDisabledForeground()

    /**
     * Hover background color
     */
    val hoverBackground: Color
        get() = JBUI.CurrentTheme.ActionButton.hoverBackground()

    /**
     * Connected status color
     */
    val connected: Color
        get() = success

    /**
     * Disconnected status color
     */
    val disconnected: Color
        get() = textSecondary

    /**
     * Connecting status color
     */
    val connecting: Color
        get() = warning

    /**
     * Error status color (same as error)
     */
    val errorStatus: Color
        get() = error
}
