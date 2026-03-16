// TextInserter.swift
// TypeBoost
//
// Uses the macOS Accessibility API to:
//   1. Determine the on-screen position of the text cursor (caret).
//   2. Replace the partially-typed word with the accepted suggestion.
//
// Both operations require the Accessibility permission to be granted.

import Cocoa
import ApplicationServices

enum TextInserter {

    // MARK: – Synthetic Event Tag

    /// Magic value written to CGEvent.eventSourceUserData on all synthetic
    /// keystrokes so the CGEventTap can ignore self-generated events.
    static let syntheticEventTag: Int64 = 0x54425F53594E  // "TB_SYN"

    // MARK: – Position Tracking (set from KeyboardMonitor)

    /// Last mouse click position in AppKit screen coordinates (bottom-left origin).
    static var lastClickPosition: CGPoint?

    /// Mouse position at last keystroke, in AppKit screen coordinates.
    static var lastKnownMousePosition: CGPoint?

    // MARK: – App Lists

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Dev",
        "org.mozilla.firefox",
        "com.apple.Safari",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    private static let electronBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.notion.id",
        "com.linear.Linear",
        "com.figma.Desktop",
        "com.slack.Slack",
        "com.discord.Discord",
        "md.obsidian",
    ]

    // MARK: – Public API

    /// Returns the screen rect of the text cursor (caret) in AppKit coordinates
    /// (bottom-left origin). Uses a cascading strategy so the bar is never off-screen.
    static func cursorRect() -> NSRect {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let fallback = NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 2, height: 16)

        let isBrowserOrElectron = browserBundleIDs.contains(bundleID)
            || electronBundleIDs.contains(bundleID)
            || bundleID.lowercased().contains("electron")

        if isBrowserOrElectron {
            // Try AX caret first — works for <textarea>, <input>, contentEditable.
            if let axRect = strategy1_axCaretBounds(),
               isReasonableCaretRect(axRect, forBundleID: bundleID) {
                return axRect
            }
            // AX failed or returned garbage — fall back to browser-specific strategies.
            return strategy2_browserPosition()
                ?? strategy3_lastMouseClickPosition()
                ?? strategy4_activeWindowCentre()
                ?? fallback
        } else {
            // Native apps: full cascade starting with precise AX caret.
            return strategy1_axCaretBounds()
                ?? strategy2_browserPosition()
                ?? strategy3_lastMouseClickPosition()
                ?? strategy4_activeWindowCentre()
                ?? fallback
        }
    }

    // MARK: – Strategy 1: AX Caret Bounds (works in native apps)

    private static func strategy1_axCaretBounds() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedObj = focusedRef else { return nil }
        let focused = focusedObj as! AXUIElement

        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeVal = rangeRef else { return nil }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeVal as! AXValue, .cfRange, &cfRange) else { return nil }

        // Zero—length range at the caret position — not the selection rect.
        var caretRange = CFRange(location: cfRange.location + cfRange.length, length: 0)
        guard let caretAXValue = AXValueCreate(.cfRange, &caretRange) else { return nil }

        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            caretAXValue,
            &boundsRef
        ) == .success, let boundsVal = boundsRef else { return nil }

        var cgRect = CGRect.zero
        guard AXValueGetValue(boundsVal as! AXValue, .cgRect, &cgRect) else { return nil }

        // Sanity check: reject obviously wrong values (off-screen iframe, etc.).
        guard cgRect.origin.x > 0,
              cgRect.origin.y > 0,
              cgRect.origin.x < 10000,
              cgRect.origin.y < 10000 else { return nil }

        return flipped(cgRect)
    }

    // MARK: – Strategy 2: Browser / Electron Window + Click Anchor

    private static func strategy2_browserPosition() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Get the focused *window* (not the focused text element, which may be
        // an off-screen iframe in browser/Electron apps).
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success, let windowObj = windowRef else { return nil }
        let window = windowObj as! AXUIElement

        var posRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)

        var winPos  = CGPoint.zero
        var winSize = CGSize.zero
        if let p = posRef  { AXValueGetValue(p as! AXValue, .cgPoint, &winPos)  }
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize,  &winSize) }

        guard winSize.width > 100, winSize.height > 100 else { return nil }

        // Convert window position from AX (top-left origin) to AppKit (bottom-left origin).
        guard let screen = NSScreen.main else { return nil }
        let winAppKitY = screen.frame.height - winPos.y - winSize.height
        let windowFrame = NSRect(x: winPos.x, y: winAppKitY,
                                 width: winSize.width, height: winSize.height)

        // Use the last click or keystroke mouse position as the cursor anchor.
        if let lastPos = lastClickPosition ?? lastKnownMousePosition {
            if windowFrame.contains(lastPos) {
                return NSRect(x: lastPos.x, y: lastPos.y + 4, width: 2, height: 17)
            }
        }

        // No valid click recorded — estimate centre-left of window.
        return NSRect(
            x: windowFrame.minX + 80,
            y: windowFrame.midY,
            width: 2,
            height: 17
        )
    }

    // MARK: – Strategy 3: Last Mouse Click Position

    private static func strategy3_lastMouseClickPosition() -> NSRect? {
        guard let click = lastClickPosition ?? lastKnownMousePosition else { return nil }
        return NSRect(x: click.x, y: click.y + 4, width: 2, height: 17)
    }

    // MARK: – Strategy 4: Active Window Centre (last resort)

    private static func strategy4_activeWindowCentre() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success else {
            if let screen = NSScreen.main {
                return NSRect(x: screen.frame.midX, y: screen.frame.midY, width: 2, height: 20)
            }
            return nil
        }

        // AXUIElement is a CF type — force cast is safe after .success check.
        let window = windowRef as! AXUIElement

        var positionRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)

        var position = CGPoint.zero
        var size = CGSize.zero
        if let p = positionRef { AXValueGetValue(p as! AXValue, .cgPoint, &position) }
        if let s = sizeRef     { AXValueGetValue(s as! AXValue, .cgSize,  &size)     }

        // Convert from AX to AppKit coordinates.
        guard let screen = NSScreen.main else { return nil }
        let appKitY = screen.frame.height - position.y - size.height

        return NSRect(
            x: position.x + 40,
            y: appKitY + size.height * 0.45,
            width: 2,
            height: 20
        )
    }

    // MARK: – Browser AX Validity Check

    /// Checks whether an AX-reported caret rect is plausible for a browser/Electron app.
    /// Rejects positions that are clearly wrong: at the window origin, off-screen,
    /// or suspiciously at (0,0) which browsers report for hidden iframes.
    private static func isReasonableCaretRect(_ rect: NSRect, forBundleID bundleID: String) -> Bool {
        // Reject zero-origin rects (common AX garbage for hidden iframes).
        guard rect.origin.x > 10, rect.origin.y > 10 else { return false }

        // Reject if the caret is not within any screen's visible frame.
        let inAnyScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(rect)
        }
        guard inAnyScreen else { return false }

        // Reject if suspiciously close to the AX window origin (common misreport).
        if let app = NSWorkspace.shared.frontmostApplication {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            var windowRef: AnyObject?
            if AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &windowRef
            ) == .success, let windowObj = windowRef {
                let window = windowObj as! AXUIElement
                var posRef: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
                var winPos = CGPoint.zero
                if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &winPos) }

                if let screen = NSScreen.main {
                    let winAppKitY = screen.frame.height - winPos.y
                    let distFromOrigin = hypot(rect.origin.x - winPos.x, rect.origin.y - winAppKitY)
                    if distFromOrigin < 15 { return false }
                }
            }
        }

        // Reject impossibly tall or wide caret rects (AX sometimes returns entire field bounds).
        guard rect.height < 100, rect.width < 50 else { return false }

        return true
    }

    // MARK: – Coordinate Flip Helper

    /// Converts AX coordinates (top-left origin) to AppKit coordinates (bottom-left origin).
    private static func flipped(_ rect: CGRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
        }) ?? NSScreen.main else { return NSRect(origin: rect.origin, size: rect.size) }

        let flippedY = screen.frame.height - rect.origin.y - rect.size.height
        return NSRect(
            x: rect.origin.x,
            y: flippedY,
            width: max(rect.size.width, 2),
            height: max(rect.size.height, 16)
        )
    }

    // MARK: – Word Replacement (spell correction)

    /// Selects the entire word under the cursor using AX, then replaces it.
    /// Used for spell-correction mode where the word is already committed.
    static func replaceWord(wordLength: Int, replacement: String) {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedObj = focusedRef else { return }
        let focused = focusedObj as! AXUIElement

        // Get current cursor position.
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeObj = rangeRef else { return }

        var cfRange = CFRange(location: 0, length: 0)
        AXValueGetValue(rangeObj as! AXValue, .cfRange, &cfRange)

        // Get the full text to find word boundaries.
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef
        ) == .success, let fullText = valueRef as? String else { return }

        let str = fullText as NSString
        let cursorIndex = cfRange.location

        // Walk backwards to find word start.
        var start = cursorIndex
        while start > 0 {
            let c = str.character(at: start - 1)
            guard let scalar = UnicodeScalar(c) else { break }
            let ch = Character(scalar)
            if !ch.isLetter && ch != "'" { break }
            start -= 1
        }

        // Walk forwards to find word end.
        var end = cursorIndex
        while end < str.length {
            let c = str.character(at: end)
            guard let scalar = UnicodeScalar(c) else { break }
            let ch = Character(scalar)
            if !ch.isLetter && ch != "'" { break }
            end += 1
        }

        guard end > start else { return }

        // Select the word range.
        var wordRange = CFRange(location: start, length: end - start)
        guard let selectValue = AXValueCreate(.cfRange, &wordRange) else { return }
        AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            selectValue
        )

        // Replace the selection.
        AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            replacement as CFTypeRef
        )
    }

    // MARK: – Text Insertion (next-word)

    /// Inserts text at the current cursor position without deleting anything first.
    /// Used for next-word prediction where there is no partial word to replace.
    static func insertAtCursor(_ text: String) {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedObj = focusedRef else { return }
        let focused = focusedObj as! AXUIElement

        // Set selected text to our word — since selection is zero-length,
        // this inserts rather than replaces.
        AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
    }

    // MARK: – Text Replacement (completion)

    /// Deletes `partialLength` characters before the cursor, then types
    /// the `replacement` string. Uses CGEvent-based keystroke simulation
    /// for maximum compatibility across apps.
    static func replaceCurrent(partialLength: Int, replacement: String) {
        // Step 1: delete the partial word using Backspace keystrokes.
        for _ in 0..<partialLength {
            postKeyStroke(keyCode: 0x33, flags: []) // kVK_Delete
        }

        // Step 2: type each character of the replacement.
        // Using CGEvent key-down / key-up with Unicode string injection.
        let source = CGEventSource(stateID: .hidSystemState)
        for char in replacement.utf16 {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }

            var unichar = char
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unichar)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unichar)
            keyDown.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            keyUp.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: – Private Helpers

    private static func postKeyStroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        keyUp.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
