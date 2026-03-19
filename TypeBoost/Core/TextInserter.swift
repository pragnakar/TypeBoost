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

    // MARK: – Cursor Position Cache

    /// The last AX-verified cursor rect (AppKit coordinates).
    /// Used to estimate position when AX returns garbage in browsers.
    private static var cachedCursorRect: NSRect?

    /// When the cached position was last validated by a successful AX call.
    private static var cachedCursorTimestamp: Date?

    /// Bundle ID when the cache was populated. Invalidated on app switch.
    private static var cachedCursorBundleID: String?

    /// Estimated character width for horizontal position tracking (px).
    /// Updated from actual AX measurements when available.
    private static var estimatedCharWidth: CGFloat = 8.0

    /// Estimated line height in points. Updated from AX caret rect height.
    /// Used for vertical nudge on Enter and Strategy 2 vertical drift.
    static var estimatedLineHeight: CGFloat = 20.0

    /// How many Enter/newline keypresses since the last mouse click or AX anchor.
    /// Used by Strategy 2 to estimate vertical drift from the last known click position.
    static var linesTypedSinceLastClick: Int = 0

    /// Invalidate the cursor cache (call on app switch or mouse click).
    static func invalidateCursorCache() {
        cachedCursorRect = nil
        cachedCursorTimestamp = nil
        cachedCursorBundleID = nil
        cumulativeNudge = 0
        linesTypedSinceLastClick = 0
    }

    /// How far the cached position has drifted from the last AX-verified anchor.
    private static var cumulativeNudge: CGFloat = 0
    /// Maximum horizontal drift before forcing a re-anchor via AX.
    /// Most text areas are 400-900px wide. After ~500px of drift the cached
    /// position is almost certainly wrong (line wrap, scroll, resize).
    private static let maxNudgeDrift: CGFloat = 500

    /// Nudge the cached cursor position by a character delta.
    /// +1 for a typed character, -1 for backspace.
    /// If the nudged position would leave the visible screen area or has
    /// drifted too far from the last AX anchor, the cache is invalidated
    /// so the next call to cursorRect() does a fresh AX query to re-anchor.
    static func nudgeCachedPosition(by charDelta: Int) {
        guard var rect = cachedCursorRect else { return }
        let delta = CGFloat(charDelta) * estimatedCharWidth
        rect.origin.x += delta
        cumulativeNudge += abs(delta)

        // Detect probable line wrap or scroll: nudged position is outside
        // any screen's visible frame, or has drifted very far from the anchor.
        let nudgedPoint = CGPoint(x: rect.origin.x, y: rect.origin.y)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(nudgedPoint) }
        if !onScreen || cumulativeNudge > maxNudgeDrift {
            invalidateCursorCache()
            return
        }

        cachedCursorRect = rect
    }

    /// Nudge the cached cursor position to the next line (Enter keypress).
    /// Moves Y down by estimatedLineHeight and resets horizontal nudge tracking.
    /// The async AX/JS reposition corrects the exact position shortly after.
    static func nudgeCachedPositionForNewLine() {
        linesTypedSinceLastClick += 1
        guard var rect = cachedCursorRect else { return }
        // AppKit Y increases upward, so moving down one line means subtracting.
        rect.origin.y -= estimatedLineHeight
        cumulativeNudge = 0   // New line resets horizontal drift counter.
        cachedCursorRect = rect
    }

    /// Returns the cached/nudged cursor position WITHOUT calling AX.
    /// Use this for mid-word typing where the position is being tracked
    /// by nudging. Returns nil if no cached position is available (caller
    /// should fall back to `cursorRect()` for a full AX query).
    static func trackedCursorRect() -> NSRect? {
        guard let cached = cachedCursorRect,
              let ts = cachedCursorTimestamp,
              Date().timeIntervalSince(ts) < 5.0 else { return nil }
        return cached
    }

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

    // MARK: – JavaScript Injection Support

    /// AppleScript application names for Chromium-based browsers.
    /// Used to build the `execute front window's active tab javascript` command.
    private static let chromiumAppNames: [String: String] = [
        "com.google.Chrome":           "Google Chrome",
        "com.microsoft.edgemac":       "Microsoft Edge",
        "com.microsoft.edgemac.Dev":   "Microsoft Edge Dev",
        "com.brave.Browser":           "Brave Browser",
        "com.operasoftware.Opera":     "Opera",
        "com.vivaldi.Vivaldi":         "Vivaldi",
        "company.thebrowser.Browser":  "Arc",
    ]

    /// Consecutive AppleScript execution errors per bundle ID.
    /// JS returning 'null' (e.g. focused on <input>) is NOT counted — only real
    /// AppleScript failures (setting disabled, browser not responding) count.
    /// Once a browser hits maxJSFailures it is skipped until the count is reset.
    /// Persisted to UserDefaults with a 24-hour TTL so re-enabling "Allow JavaScript
    /// from Apple Events" takes effect on the next app launch without needing a reset.
    private static var jsFailureCount: [String: Int] = {
        let now = Date().timeIntervalSince1970
        let saved = UserDefaults.standard.dictionary(forKey: "TypeBoost.jsFailureCount")
            as? [String: Int] ?? [:]
        let dates = UserDefaults.standard.dictionary(forKey: "TypeBoost.jsFailureCountDate")
            as? [String: Double] ?? [:]
        // Discard entries older than 24 hours so a user who enables the setting
        // gets a fresh start on next launch without having to clear prefs manually.
        return saved.filter { id, _ in
            guard let ts = dates[id] else { return false }
            return now - ts < 86400
        }
    }()
    private static let maxJSFailures = 3

    /// Persists the current failure count for one bundle ID to UserDefaults.
    /// Called after every increment and every reset so the on-disk state stays in sync.
    private static func persistJSFailureCount(for bundleID: String) {
        var saved = UserDefaults.standard.dictionary(forKey: "TypeBoost.jsFailureCount")
            as? [String: Int] ?? [:]
        var dates = UserDefaults.standard.dictionary(forKey: "TypeBoost.jsFailureCountDate")
            as? [String: Double] ?? [:]
        saved[bundleID] = jsFailureCount[bundleID] ?? 0
        dates[bundleID] = Date().timeIntervalSince1970
        UserDefaults.standard.set(saved, forKey: "TypeBoost.jsFailureCount")
        UserDefaults.standard.set(dates, forKey: "TypeBoost.jsFailureCountDate")
    }

    /// Dedicated serial queue for NSAppleScript execution.
    /// NSAppleScript is not thread-safe on arbitrary threads; a single serial queue
    /// keeps all executions sequential and avoids run-loop conflicts.
    private static let appleScriptQueue = DispatchQueue(
        label: "com.typeBoost.appleScript", qos: .userInitiated)

    /// Compiled NSAppleScript instances keyed by bundle ID.
    /// Compiled once per session — subsequent executeAndReturnError calls reuse
    /// the bytecode, cutting latency from ~50ms (Process spawn) to ~5–10ms.
    private static var compiledScripts: [String: NSAppleScript] = [:]

    /// Returns a compiled (and cached) NSAppleScript for the given browser.
    /// Must be called from appleScriptQueue.
    private static func compiledScript(for bundleID: String) -> NSAppleScript? {
        if let cached = compiledScripts[bundleID] { return cached }

        let source: String
        if let appName = chromiumAppNames[bundleID] {
            source = "tell application \"\(appName)\"\n" +
                     "execute front window's active tab javascript \"\(caretJS)\"\n" +
                     "end tell"
        } else if bundleID == "com.apple.Safari" {
            source = "tell application \"Safari\"\n" +
                     "do JavaScript \"\(caretJS)\" in front document\n" +
                     "end tell"
        } else {
            return nil
        }

        guard let script = NSAppleScript(source: source) else { return nil }
        var compileError: NSDictionary?
        script.compileAndReturnError(&compileError)
        guard compileError == nil else { return nil }
        compiledScripts[bundleID] = script
        return script
    }

    /// Minified JS injected into the frontmost browser tab via AppleScript.
    /// Returns the caret's screen position as JSON {x, y, h}, or a sentinel string.
    ///
    /// Sentinel values (not counted as failures):
    ///   'native' — focused element is <input>/<textarea>/<select>; AX handles these.
    ///   'null'   — no text selection / element not visible.
    ///
    /// Canvas-editor support (these don't expose a real selection to the browser):
    ///   .kix-cursor-caret  — Google Docs  (kix engine, getSelection() always empty)
    ///   .CodeMirror-cursor — CodeMirror 5  (Overleaf, GitHub web editor, Replit, …)
    ///   .cm-cursor         — CodeMirror 6  (Obsidian web, newer Replit, …)
    ///   .monaco-editor .cursor — Monaco    (vscode.dev, StackBlitz, CodeSandbox, …)
    ///
    /// Standard contenteditable (Gmail, Notion, Twitter, …) uses window.getSelection().
    /// Single quotes only — safe inside an AppleScript double-quoted string.
    private static let caretJS =
        "(function(){" +
        "var el=document.activeElement;" +
        "if(el&&(el.tagName==='INPUT'||el.tagName==='TEXTAREA'||el.tagName==='SELECT'))return 'native';" +
        // fromEl: shared helper — converts any positioned DOM element to a JSON coord string.
        "function fromEl(e){if(!e)return null;" +
        "var r=e.getBoundingClientRect();if(r.height<=0)return null;" +
        "var h=r.height>4?r.height:20;" +
        "return JSON.stringify({x:r.left+window.screenX,y:r.top+window.screenY,h:h});}" +
        // Try canvas-editor cursor elements before falling back to getSelection().
        "var res=fromEl(document.querySelector('.kix-cursor-caret'))" +
        "||fromEl(document.querySelector('.CodeMirror-cursor'))" +
        "||fromEl(document.querySelector('.cm-cursor'))" +
        "||fromEl(document.querySelector('.monaco-editor .cursor'));" +
        "if(res)return res;" +
        // Standard contenteditable / rich-text editors.
        "var s=window.getSelection();" +
        "if(!s||s.rangeCount===0)return 'null';" +
        "var r=s.getRangeAt(0).getBoundingClientRect();" +
        "if(r.x===0&&r.y===0&&r.width===0&&r.height===0)return 'null';" +
        "var lh=parseFloat(window.getComputedStyle(el||document.body).lineHeight);" +
        "var h=(!isNaN(lh)&&lh>4&&lh<200)?lh:(r.height>2?r.height:20);" +
        "return JSON.stringify({x:r.left+window.screenX,y:r.top+window.screenY,h:h});" +
        "})()"

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
    /// (bottom-left origin). Uses a cascading strategy with position caching
    /// so the bar tracks smoothly even when AX returns garbage in browsers.
    static func cursorRect() -> NSRect {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let fallback = NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 2, height: 16)

        let isBrowserOrElectron = browserBundleIDs.contains(bundleID)
            || electronBundleIDs.contains(bundleID)
            || bundleID.lowercased().contains("electron")

        // Invalidate cache if the app changed.
        if bundleID != cachedCursorBundleID {
            invalidateCursorCache()
            cachedCursorBundleID = bundleID
        }

        // --- Strategy 1: AX caret bounds ---
        if let axRect = strategy1_axCaretBounds() {
            let passesValidation = isBrowserOrElectron
                ? isReasonableCaretRect(axRect, forBundleID: bundleID)
                : true  // Native apps: trust AX unconditionally

            if passesValidation {
                // Update char-width estimate from consecutive same-line AX reads.
                if let prev = cachedCursorRect {
                    let dy = abs(axRect.origin.y - prev.origin.y)
                    if dy < 4 {                              // Same line
                        let dx = abs(axRect.origin.x - prev.origin.x)
                        if dx > 2 && dx < 30 {
                            estimatedCharWidth = estimatedCharWidth * 0.8 + dx * 0.2
                        }
                    } else if dy > 4 && dy < 80 {           // Line change
                        estimatedLineHeight = estimatedLineHeight * 0.8 + dy * 0.2
                    }
                }
                // Also learn line height directly from caret rect height.
                if axRect.height > 8 && axRect.height < 80 {
                    estimatedLineHeight = estimatedLineHeight * 0.8 + axRect.height * 0.2
                }

                cachedCursorRect = axRect
                cachedCursorTimestamp = Date()
                cumulativeNudge = 0
                linesTypedSinceLastClick = 0   // AX re-anchored — reset drift counter.
                return axRect
            }
        }

        // --- Strategy 1 failed: use cached position if recent ---
        // In browsers, AX fails intermittently. A cached position from < 2s ago
        // is far more accurate than falling back to mouse position.
        if let cached = cachedCursorRect,
           let ts = cachedCursorTimestamp,
           Date().timeIntervalSince(ts) < 2.0 {
            return cached
        }

        // --- Stale or no cache: fall through to heuristic strategies ---
        if isBrowserOrElectron {
            let result = strategy2_browserPosition()
                ?? strategy3_lastMouseClickPosition()
                ?? strategy4_activeWindowCentre()
                ?? fallback
            // Cache the heuristic result too, so subsequent nudges work.
            cachedCursorRect = result
            cachedCursorTimestamp = Date()
            return result
        } else {
            return strategy2_browserPosition()
                ?? strategy3_lastMouseClickPosition()
                ?? strategy4_activeWindowCentre()
                ?? fallback
        }
    }

    // MARK: – Strategy 1: AX Caret Bounds (works in native apps)

    /// Full AX caret bounds query with a configurable timeout.
    /// Default 0.1s is appropriate for background calls (asyncRepositionBar).
    /// Pass 0.02s for cold-start fast path (fastCursorRect) on the main thread.
    private static func strategy1_axCaretBounds(timeout: Float = 0.1) -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)

        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedObj = focusedRef else { return nil }
        let focused = focusedObj as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, timeout)

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

    /// Synchronous AX caret query with a very tight 20ms timeout.
    /// Used for the cold-start initial bar position (no cached rect) so the bar
    /// appears in the correct place immediately rather than jumping ~50ms later.
    /// Returns nil quickly if AX is slow — caller falls back to mouse location.
    /// Must be called on the main thread.
    static func fastCursorRect() -> NSRect? {
        strategy1_axCaretBounds(timeout: 0.02)
    }

    // MARK: – Strategy 2: Browser / Electron Window + Click Anchor

    private static func strategy2_browserPosition() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)

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
        // AX Y is relative to primary screen top, so always use primary screen height.
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let winAppKitY = primaryScreen.frame.height - winPos.y - winSize.height
        let windowFrame = NSRect(x: winPos.x, y: winAppKitY,
                                 width: winSize.width, height: winSize.height)

        // Use the last click or keystroke mouse position as the cursor anchor,
        // adjusted downward by however many lines have been typed since the click.
        if let lastPos = lastClickPosition ?? lastKnownMousePosition {
            if windowFrame.contains(lastPos) {
                // AppKit Y increases upward, so more lines = smaller Y value.
                let verticalDrift = CGFloat(linesTypedSinceLastClick) * estimatedLineHeight
                let estimatedY = max(windowFrame.minY + 4, lastPos.y - verticalDrift)
                return NSRect(x: lastPos.x, y: estimatedY, width: 2, height: estimatedLineHeight)
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
        AXUIElementSetMessagingTimeout(appElement, 0.1)

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
        // AX Y is relative to primary screen top — always use primary height.
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let appKitY = primaryScreen.frame.height - position.y - size.height

        return NSRect(
            x: position.x + 40,
            y: appKitY + size.height * 0.45,
            width: 2,
            height: 20
        )
    }

    // MARK: – Strategy 0: JavaScript Injection via NSAppleScript

    /// Asks the frontmost browser tab for the caret's screen rect via a compiled
    /// NSAppleScript. Must be called from `appleScriptQueue`.
    ///
    /// Failure counting:
    ///   • AppleScript execution error (setting disabled, browser crash) → increments
    ///     jsFailureCount. After maxJSFailures the browser is skipped for the session.
    ///   • JS returning 'null' (no selection) or 'native' (<input>/<textarea>) is
    ///     NOT counted as a failure — these are normal cases handled by AX fallback.
    ///
    /// Coordinate maths:
    ///   JS gives (x, y) in CSS pixels from screen top-left (same as AX/CG space).
    ///   AppKit origin is bottom-left:  appKitY = screenH - jsY - lineH
    /// Maximum time (seconds) to wait for a single NSAppleScript execution.
    /// If the target app is suspended (e.g. screen asleep), executeAndReturnError
    /// blocks indefinitely. This timeout ensures we never hang the appleScriptQueue
    /// longer than a few seconds — the WindowServer watchdog fires at 40s.
    private static let jsExecutionTimeout: TimeInterval = 5.0

    static func jsCaretRect(bundleID: String, primaryScreenHeight: CGFloat) -> NSRect? {
        guard (jsFailureCount[bundleID] ?? 0) < maxJSFailures else { return nil }
        guard let script = compiledScript(for: bundleID) else { return nil }

        // Run executeAndReturnError on a separate work item with a timeout.
        // If the browser is suspended (screen asleep), this prevents an
        // indefinite block that can starve WindowServer.
        var error: NSDictionary?
        var result: NSAppleEventDescriptor?
        let workItem = DispatchWorkItem {
            var execError: NSDictionary?
            let execResult = script.executeAndReturnError(&execError)
            error = execError
            result = execResult
        }
        let deadline: DispatchTime = .now() + jsExecutionTimeout
        // We're already on appleScriptQueue, so dispatch to a concurrent queue
        // and wait with a timeout.
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
        let timedOut = workItem.wait(timeout: deadline) == .timedOut
        if timedOut {
            workItem.cancel()
            return nil
        }

        guard error == nil else {
            // Real AppleScript failure — "Allow JavaScript from Apple Events" likely off.
            jsFailureCount[bundleID] = (jsFailureCount[bundleID] ?? 0) + 1
            persistJSFailureCount(for: bundleID)
            return nil
        }

        let raw = result?.stringValue ?? ""
        // 'native' → focused element is <input>/<textarea>; use AX instead (not a failure).
        // 'null'   → no selection in current element (not a failure).
        guard raw != "native", raw != "null", !raw.isEmpty else { return nil }

        guard let jsonData = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Double],
              let jsX = json["x"], let jsY = json["y"], let jsH = json["h"],
              jsH >= 2 else { return nil }

        // Success — reset failure counter (persist so a re-enabled setting is honoured
        // immediately on the next launch rather than waiting for the TTL to expire).
        jsFailureCount[bundleID] = 0
        persistJSFailureCount(for: bundleID)

        let appKitY = primaryScreenHeight - jsY - jsH
        let rect = NSRect(x: jsX, y: appKitY, width: 2, height: jsH)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        return rect
    }

    // MARK: – Async Accurate Cursor Rect

    /// Tries JS injection for browsers (on appleScriptQueue) then falls back to AX.
    /// This is the preferred call site for the async reposition task in AppDelegate.
    static func accurateCursorRect(bundleID: String) async -> NSRect {
        let isBrowserOrElectron = browserBundleIDs.contains(bundleID)
            || electronBundleIDs.contains(bundleID)
            || bundleID.lowercased().contains("electron")
        let hasJSPath = chromiumAppNames[bundleID] != nil || bundleID == "com.apple.Safari"

        if isBrowserOrElectron && hasJSPath {
            let screenH = await MainActor.run { NSScreen.screens.first?.frame.height ?? 900.0 }

            // Run on dedicated serial queue — NSAppleScript must not be called concurrently.
            let jsRect: NSRect? = await withCheckedContinuation { cont in
                appleScriptQueue.async {
                    cont.resume(returning: jsCaretRect(bundleID: bundleID,
                                                       primaryScreenHeight: screenH))
                }
            }

            if let rect = jsRect {
                await MainActor.run {
                    cachedCursorRect = rect
                    cachedCursorTimestamp = Date()
                    cumulativeNudge = 0
                    linesTypedSinceLastClick = 0
                    // Learn line height from JS measurement.
                    if rect.height > 4 && rect.height < 80 {
                        estimatedLineHeight = estimatedLineHeight * 0.8 + rect.height * 0.2
                    }
                }
                return rect
            }
        }

        // Fall back to the synchronous AX cascade on the main actor.
        return await MainActor.run { cursorRect() }
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

                if let primaryScreen = NSScreen.screens.first {
                    let winAppKitY = primaryScreen.frame.height - winPos.y
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
    ///
    /// The incoming `rect` is in AX/CG screen coordinates where Y=0 is the
    /// top of the **primary** screen and Y increases downward. AppKit's
    /// coordinate system has Y=0 at the bottom of the primary screen with
    /// Y increasing upward. The conversion is:
    ///     appKitY = primaryScreenHeight - axY - rectHeight
    ///
    /// We always use the primary screen height for the flip because AX
    /// coordinates are defined relative to the primary display's top-left,
    /// regardless of which physical screen the point is on.
    private static func flipped(_ rect: CGRect) -> NSRect {
        guard let primaryScreen = NSScreen.screens.first else {
            return NSRect(origin: rect.origin, size: rect.size)
        }

        let primaryHeight = primaryScreen.frame.height
        let flippedY = primaryHeight - rect.origin.y - rect.size.height
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
