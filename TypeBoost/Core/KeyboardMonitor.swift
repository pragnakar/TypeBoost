// KeyboardMonitor.swift
// TypeBoost
//
// Installs a global CGEventTap to observe every keyDown event system-wide.
// The tap runs on a dedicated background thread so the main thread is never
// blocked. Recognised events are converted to the `KeyboardEvent` enum and
// forwarded via the `onKeyEvent` closure on the main queue.
//
// Privacy: the tap is passive (`.listenOnly` would suffice for observation,
// but we use `.cgSessionEventTap` + an active tap so we can **consume**
// arrow/Enter/Option+N keys when the suggestion bar is active, preventing
// them from reaching the target application).

import Cocoa
import Carbon.HIToolbox

// MARK: – KeyboardEvent

/// A simplified, app-level representation of a key press.
enum KeyboardEvent {
    case character(Character)
    case backspace
    case space
    case punctuation
    case escape
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case enter
    /// Plain digit (1-3) for quick-select when suggestions are visible.
    case numberSelect(Int)
    /// Mouse button pressed — user may be starting a window drag.
    case mouseDown
    /// Mouse click released — user may have clicked on a word.
    case mouseUp
    /// Scroll wheel / trackpad scroll — bar may need repositioning.
    case scroll
    case other
}

// MARK: – KeyboardMonitor

final class KeyboardMonitor {

    /// Called on the **main queue** for every relevant key event.
    var onKeyEvent: ((KeyboardEvent) -> Void)?

    /// Called from the CGEventTap **background thread** to check if
    /// the suggestion bar is currently showing. Must be thread-safe.
    var areSuggestionsVisible: (() -> Bool)?

    /// Called from the CGEventTap **background thread** to check if
    /// keyboard-driven selection mode is active. Must be thread-safe.
    var isNavigationActive: (() -> Bool)?

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    /// The CFRunLoop running on the background tap thread.
    /// Stored at tap-install time so stop() can remove sources and stop
    /// the RunLoop from the main thread without touching the wrong RunLoop.
    private var tapRunLoop: CFRunLoop?
    private var isRunning = false

    // MARK: – Public

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // The tap must be created and its RunLoop run on a background thread
        // so we never block the main thread.
        tapThread = Thread { [weak self] in
            self?.installTap()
            RunLoop.current.run()
        }
        tapThread?.name = "com.typeboost.keyboard-monitor"
        tapThread?.qualityOfService = .userInteractive
        tapThread?.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        // Disable the tap first so no new events are delivered.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        // Remove the source from the background thread's RunLoop (not the
        // main thread's — CFRunLoopGetCurrent() in stop() is the main RunLoop,
        // which never had this source). Then stop the RunLoop so the background
        // thread exits cleanly instead of running forever with an orphaned source.
        if let source = runLoopSource, let runLoop = tapRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }

        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
    }

    // MARK: – Private

    private func installTap() {
        // Capture the background thread's RunLoop before anything else so
        // stop() can target it correctly from the main thread.
        tapRunLoop = CFRunLoopGetCurrent()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)
                              | (1 << CGEventType.leftMouseDown.rawValue)
                              | (1 << CGEventType.leftMouseUp.rawValue)
                              | (1 << CGEventType.scrollWheel.rawValue)

        // Store `self` as a raw pointer so the C callback can reach us.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,      // active tap — can consume events
            eventsOfInterest: mask,
            callback: keyboardTapCallback,
            userInfo: selfPtr
        ) else {
            NSLog("[TypeBoost] Failed to create CGEventTap. Check Accessibility permissions.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Translates a `CGEvent` into a `KeyboardEvent`.
    fileprivate func translate(_ cgEvent: CGEvent) -> KeyboardEvent? {
        let keyCode = cgEvent.getIntegerValueField(.keyboardEventKeycode)
        let flags = cgEvent.flags

        // Modifier-only events (flagsChanged) are ignored.
        if cgEvent.type == .flagsChanged { return nil }

        // Ignore events with Command held (keyboard shortcuts).
        if flags.contains(.maskCommand) { return nil }

        // When suggestions are visible, plain 1/2/3 trigger number-select.
        let suggestionsUp = areSuggestionsVisible?() ?? false
        if suggestionsUp && !flags.contains(.maskAlternate) {
            switch keyCode {
            case kVK_ANSI_1: return .numberSelect(1)
            case kVK_ANSI_2: return .numberSelect(2)
            case kVK_ANSI_3: return .numberSelect(3)
            default: break
            }
        }

        switch keyCode {
        case kVK_Delete:        return .backspace
        case kVK_Space:         return .space
        case kVK_Escape:        return .escape
        case kVK_UpArrow:       return .arrowUp
        case kVK_DownArrow:     return .arrowDown
        case kVK_LeftArrow:     return .arrowLeft
        case kVK_RightArrow:    return .arrowRight
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return .enter
        case kVK_Tab:
            return .other  // Ignore tabs
        default:
            break
        }

        // Attempt to decode the character.
        guard let chars = cgEvent.keyCharacterString, let first = chars.first else {
            return .other
        }

        if first.isPunctuation || first.isSymbol || first.isNewline {
            return .punctuation
        }
        if first.isLetter || first == "'" || first == "-" {
            return .character(first)
        }
        if first.isNumber {
            return .character(first) // Digits handled upstream
        }

        return .other
    }
}

// MARK: – C Callback

/// The raw C-function callback required by `CGEvent.tapCreate`.
/// It bridges into the Swift `KeyboardMonitor` instance via the `userInfo` pointer.
///
/// Event consumption logic (Bug 1 + Bug 3):
/// - Arrow keys, Enter, Escape, and digit 1/2/3 are consumed when the
///   suggestion bar is active, preventing them from reaching the target app.
/// - All other events pass through normally.
private func keyboardTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Re-enable tap if the system disabled it (happens under heavy load).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    // Ignore self-generated synthetic events from TextInserter.
    // These keystrokes must reach the target app (pass through) but must NOT
    // be processed by our own event handler.
    if type == .keyDown {
        if event.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }
    }

    // Track mouse clicks for cursor positioning in browser/Electron apps.
    // Also dispatch .mouseDown so AppDelegate can suppress reposition during drags.
    // Convert from AX/CG (top-left origin) to AppKit (bottom-left origin) immediately.
    if type == .leftMouseDown {
        let location = event.location
        if let screenHeight = NSScreen.main?.frame.height {
            let appKitPoint = CGPoint(x: location.x, y: screenHeight - location.y)
            DispatchQueue.main.async {
                TextInserter.lastClickPosition = appKitPoint
                TextInserter.lastKnownMousePosition = appKitPoint
                monitor.onKeyEvent?(.mouseDown)
            }
        }
        return Unmanaged.passUnretained(event)  // Never consume mouse events
    }

    // On mouse up, dispatch a mouseUp event for spell-check trigger.
    if type == .leftMouseUp {
        DispatchQueue.main.async {
            monitor.onKeyEvent?(.mouseUp)
        }
        return Unmanaged.passUnretained(event)
    }

    // On scroll, dispatch a throttled reposition signal.
    // Scroll fires at 50–100Hz on trackpad — AppDelegate applies a 100ms guard
    // so only one reposition fires per scroll gesture, not one per event.
    if type == .scrollWheel {
        DispatchQueue.main.async {
            monitor.onKeyEvent?(.scroll)
        }
        return Unmanaged.passUnretained(event)
    }

    // On every keyDown, record the current mouse position (it stays put while typing).
    if type == .keyDown {
        let mousePos = NSEvent.mouseLocation  // Already in AppKit coordinates
        DispatchQueue.main.async {
            TextInserter.lastKnownMousePosition = mousePos
        }
    }

    guard let keyEvent = monitor.translate(event) else {
        return Unmanaged.passUnretained(event)
    }

    // Determine whether to consume this event BEFORE dispatching to main.
    // These closures read simple boolean properties and are safe to call
    // from the background tap thread.
    let suggestionsVisible = monitor.areSuggestionsVisible?() ?? false
    let navigationActive = monitor.isNavigationActive?() ?? false

    var shouldConsume = false
    switch keyEvent {
    case .arrowUp:
        shouldConsume = suggestionsVisible
    case .arrowDown:
        shouldConsume = suggestionsVisible
    case .arrowLeft, .arrowRight:
        shouldConsume = navigationActive
    case .enter:
        shouldConsume = navigationActive
    case .escape:
        shouldConsume = suggestionsVisible
    case .numberSelect:
        // Always consumed — numberSelect is only emitted when visible.
        shouldConsume = true
    default:
        break
    }

    // Dispatch to main queue asynchronously so the tap callback returns fast.
    DispatchQueue.main.async {
        monitor.onKeyEvent?(keyEvent)
    }

    return shouldConsume ? nil : Unmanaged.passUnretained(event)
}

// MARK: – CGEvent helpers

private extension CGEvent {
    /// Returns the characters produced by this key event using the current
    /// input source, or nil if they cannot be determined.
    var keyCharacterString: String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        self.keyboardGetUnicodeString(
            maxStringLength: 4,
            actualStringLength: &length,
            unicodeString: &chars
        )
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

// MARK: – Virtual key codes (Carbon)

private let kVK_ANSI_1: Int64 = 0x12
private let kVK_ANSI_2: Int64 = 0x13
private let kVK_ANSI_3: Int64 = 0x14
private let kVK_Return: Int64 = 0x24
private let kVK_Tab: Int64 = 0x30
private let kVK_Space: Int64 = 0x31
private let kVK_Delete: Int64 = 0x33
private let kVK_Escape: Int64 = 0x35
private let kVK_ANSI_KeypadEnter: Int64 = 0x4C
private let kVK_LeftArrow: Int64 = 0x7B
private let kVK_RightArrow: Int64 = 0x7C
private let kVK_DownArrow: Int64 = 0x7D
private let kVK_UpArrow: Int64 = 0x7E
