package com.example.jarvis_app

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class JarvisAccessibilityService : AccessibilityService() {

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        // We only care about window state changes (new panels appearing)
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            val rootNode = rootInActiveWindow ?: return
            
            // Logic to find and click toggles in the "Internet" or "Bluetooth" panels
            // This is the "Zero-Touch" magic.
            findAndClickToggle(rootNode, "Wi-Fi")
            findAndClickToggle(rootNode, "Bluetooth")
            
            rootNode.recycle()
        }
    }

    private fun findAndClickToggle(node: AccessibilityNodeInfo, text: String) {
        val nodes = node.findAccessibilityNodeInfosByText(text)
        for (n in nodes) {
            // Traverse up to find a clickable parent or switch
            var parent = n
            var depth = 0
            while (depth < 5) {
                if (parent.isClickable || parent.className == "android.widget.Switch") {
                    parent.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    return
                }
                parent = parent.parent ?: break
                depth++
            }
        }
    }

    override fun onInterrupt() {}
}
