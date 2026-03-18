// AppDelegate.swift
// TypeBoost
//
// Central coordinator that wires together every subsystem:
//   • PermissionManager  – checks Accessibility / Input Monitoring
//   • KeyboardMonitor    – global CGEventTap
//   • ContextManager     – tracks the word being typed
//   • PredictionEngine   – generates suggestions
//   • SuggestionBarWindow – floating UI
//   • MenuBarController  – status-item menu
//   • SecureInputDetector – pauses in password fields
//   • AppIgnoreList      – per-app exclusion

import Cocoa
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: – Subsystems

    private var permissionManager: PermissionManager!
    private var keyboardMonitor: KeyboardMonitor!
    private var contextManager: ContextManager!
    private var predictionEngine: PredictionEngine!
    fileprivate var suggestionWindow: SuggestionBarWindow!
    private var menuBarController: MenuBarController!
    private var secureInputDetector: SecureInputDetector!
    private var appIgnoreList: AppIgnoreList!
    private var settings: AppSettings!
    private var cancellables = Set<AnyCancellable>()

    private enum PredictionMode {
        case prefixCompletion
        case nextWord
        case spellCorrection
    }

    private var predictionMode: PredictionMode = .prefixCompletion
    /// Bundle ID of the last active application, used to detect real app switches
    /// vs. same-app reactivation (e.g. returning from Spotlight).
    private var lastActiveBundleID: String?
    /// Debounce timer for arrow-key spell-check trigger.
    private var arrowKeyDebounceTimer: Timer?
    /// Auto-dismiss timer for next-word suggestions.
    private var nextWordDismissTimer: Timer?
    /// Repeating timer that re-anchors the bar position while it's visible.
    /// Fires every 300ms so the bar tracks the cursor even without a keystroke
    /// (e.g. after scrolling, browser layout reflow, auto-indent).
    private var repositionPollTimer: Timer?
    /// Time of the last typing keystroke. The poll skips JS/AX when a keystroke
    /// fired recently — the keystroke already triggered asyncRepositionBar().
    var lastKeystrokeDate: Date = .distantPast
    /// True while the left mouse button is held down (potential window drag).
    /// All async reposition calls are suppressed during this window to prevent
    /// the bar from teleporting to stale cached coordinates mid-drag.
    private var isMouseButtonDown: Bool = false
    /// True while an asyncRepositionBar Task is already in flight.
    /// Prevents the AXObserver, poll timer, and keystroke path from all
    /// spawning concurrent Tasks that each call AX/JS queries and then
    /// race each other trying to set the window origin.
    private var isRepositionInFlight: Bool = false
    /// Consecutive poll ticks where the bar didn't move. After 3 static ticks
    /// the poll interval backs off to 1s to reduce WindowServer compositing work.
    var staticPollCount: Int = 0

    // MARK: – AXObserver (instant cursor tracking without polling)

    /// Active AXObserver for the frontmost application.
    /// Delivers kAXSelectedTextChangedNotification immediately when the cursor
    /// moves — arrow keys, mouse selection, IME — without waiting for the poll.
    private var axObserver: AXObserver?
    private var axObserverPID: pid_t = 0
    /// The focused element currently observed for selectedTextChanged.
    fileprivate var axFocusedElement: AXUIElement?

    // MARK: – Scroll throttle

    /// Last time a scroll event triggered asyncRepositionBar().
    /// Scroll fires at 50–100Hz; we reposition at most once per 100ms.
    private var lastScrollDate: Date = .distantPast

    // MARK: – Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        NSLog("[TypeBoost] applicationDidFinishLaunching called")
        #endif
        settings = AppSettings.load()
        #if DEBUG
        NSLog("[TypeBoost] Settings loaded: enabled=\(settings.isEnabled)")
        #endif
        permissionManager = PermissionManager()
        #if DEBUG
        NSLog("[TypeBoost] Accessibility=\(permissionManager.isAccessibilityGranted), InputMonitoring=\(permissionManager.isInputMonitoringGranted)")
        #endif
        appIgnoreList = AppIgnoreList(settings: settings)
        secureInputDetector = SecureInputDetector()
        contextManager = ContextManager()

        let userDictionary = UserDictionary()
        predictionEngine = PredictionEngine(userDictionary: userDictionary)
        predictionEngine.loadBigramModel()

        suggestionWindow = SuggestionBarWindow()
        menuBarController = MenuBarController(
            settings: settings,
            permissionManager: permissionManager,
            appIgnoreList: appIgnoreList,
            userDictionary: userDictionary
        )
        #if DEBUG
        NSLog("[TypeBoost] MenuBarController created")
        #endif

        menuBarController.onResetLearning = { [weak self] in
            self?.predictionEngine.resetAllLearning()
        }

        keyboardMonitor = KeyboardMonitor()

        bindEvents()

        // Attempt to start monitoring; this will fail gracefully
        // if permissions have not been granted yet.
        if permissionManager.hasRequiredPermissions {
            #if DEBUG
            NSLog("[TypeBoost] Permissions granted, starting keyboard monitor")
            #endif
            keyboardMonitor.start()
        } else {
            #if DEBUG
            NSLog("[TypeBoost] Permissions NOT granted, requesting")
            #endif
            permissionManager.requestPermissions()
        }

        // React to per-app disable/enable from the menu bar.
        // AppIgnoreList is the source of truth; AppDelegate cleans up UI and state here
        // so MenuBarController doesn't need a back-reference into AppDelegate.
        appIgnoreList.$ignoredBundleIDs
            .dropFirst() // skip the initial load
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.appIgnoreList.isCurrentAppIgnored {
                    // App was just added to ignore list — clean up exactly as global disable.
                    self.suggestionWindow.hide()
                    self.contextManager.reset()
                    self.predictionEngine.reset()
                    self.cancelNextWordMode()
                    self.predictionMode = .prefixCompletion
                    self.arrowKeyDebounceTimer?.invalidate()
                    self.arrowKeyDebounceTimer = nil
                    self.staticPollCount = 0
                    TextInserter.invalidateCursorCache()
                    TextInserter.lastClickPosition = nil
                    TextInserter.lastKnownMousePosition = nil
                } else {
                    // App was just removed from ignore list — reset stale state,
                    // same as re-enable so predictions start clean.
                    self.contextManager.reset()
                    self.predictionEngine.reset()
                    self.cancelNextWordMode()
                    self.predictionMode = .prefixCompletion
                    self.staticPollCount = 0
                    TextInserter.invalidateCursorCache()
                    TextInserter.lastClickPosition = nil
                    TextInserter.lastKnownMousePosition = nil
                }
            }
            .store(in: &cancellables)

        // Re-check permissions when app becomes active.
        // Track the initial frontmost app so the first notification
        // doesn't spuriously reset context.
        lastActiveBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .sink { [weak self] notification in self?.handleAppSwitch(notification) }
        .store(in: &cancellables)

        // Suspend on system sleep and screen sleep; resume on wake.
        // Without these, the AXObserver fires a notification burst on wake and
        // the CGEventTap may be in a disabled state, both of which overload WindowServer.
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.suspendForSleep() }
            .store(in: &cancellables)
        wsCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.suspendForSleep() }
            .store(in: &cancellables)
        wsCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.resumeAfterWake() }
            .store(in: &cancellables)
        wsCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in self?.resumeAfterWake() }
            .store(in: &cancellables)

        // Observe enable/disable toggle from settings.
        settings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled && self.permissionManager.hasRequiredPermissions {
                    self.keyboardMonitor.start()
                    // Re-attach AXObserver to the current frontmost app —
                    // it was torn down when disabled.
                    if let app = NSWorkspace.shared.frontmostApplication {
                        self.setupAXObserver(pid: app.processIdentifier)
                        self.lastActiveBundleID = app.bundleIdentifier
                    }
                    // Full state reset — user may have typed elsewhere or moved
                    // the cursor while TypeBoost was disabled.
                    self.contextManager.reset()
                    self.predictionEngine.reset()
                    self.cancelNextWordMode()
                    self.predictionMode = .prefixCompletion   // cancelNextWordMode only covers .nextWord
                    self.arrowKeyDebounceTimer?.invalidate()  // prevent stale timer firing in new context
                    self.arrowKeyDebounceTimer = nil
                    self.staticPollCount = 0                  // reset poll back-off
                    TextInserter.invalidateCursorCache()
                    TextInserter.lastClickPosition = nil      // clear browser Strategy-2 anchor
                    TextInserter.lastKnownMousePosition = nil
                } else {
                    self.keyboardMonitor.stop()
                    self.suggestionWindow.hide()
                    // Tear down ALL active monitoring so the app is truly inert
                    // while disabled. Without this, the AXObserver keeps firing
                    // and handleAppSwitch keeps calling setupAXObserver — both of
                    // which make live AX/JS calls that can block the main thread.
                    self.repositionPollTimer?.invalidate()
                    self.repositionPollTimer = nil
                    self.arrowKeyDebounceTimer?.invalidate()
                    self.arrowKeyDebounceTimer = nil
                    self.teardownAXObserver()
                    self.contextManager.reset()
                    self.predictionEngine.reset()
                    self.cancelNextWordMode()
                    self.predictionMode = .prefixCompletion
                    TextInserter.invalidateCursorCache()
                }
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardownAXObserver()
        keyboardMonitor.stop()
        predictionEngine.saveBigramModel()
        settings.save()
    }

    // MARK: – Sleep / Wake / Screen-sleep

    /// Suspend all monitoring and hide the bar on sleep or screen-off.
    /// Without this, the AXObserver fires a burst of notifications on wake
    /// (every app restoring its window state), flooding asyncRepositionBar
    /// and hammering WindowServer with concurrent AX queries and reposition calls.
    private func suspendForSleep() {
        repositionPollTimer?.invalidate()
        repositionPollTimer = nil
        teardownAXObserver()
        keyboardMonitor.stop()
        suggestionWindow.hide()
        contextManager.reset()
        predictionEngine.reset()
        cancelNextWordMode()
        predictionMode = .prefixCompletion
        TextInserter.invalidateCursorCache()
    }

    /// Resume monitoring after wake. Delay 1s to let the AX subsystem
    /// and all apps finish restoring their window state — prevents an
    /// immediate burst of stale AX notifications from the AXObserver.
    private func resumeAfterWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.settings.isEnabled,
                  self.permissionManager.hasRequiredPermissions else { return }
            self.keyboardMonitor.start()
            if let app = NSWorkspace.shared.frontmostApplication {
                self.setupAXObserver(pid: app.processIdentifier)
                self.lastActiveBundleID = app.bundleIdentifier
            }
        }
    }

    // MARK: – Event Binding

    /// Connects the keyboard monitor output to the context manager,
    /// prediction engine, and UI.
    private func bindEvents() {
        keyboardMonitor.onKeyEvent = { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // These closures are called from the CGEventTap background thread
        // to decide whether to consume key events before they reach apps.
        // Use atomic flags to avoid DispatchQueue.main.sync which can deadlock
        // if the main thread is blocked on a slow AX call.
        keyboardMonitor.areSuggestionsVisible = { [weak self] in
            self?.suggestionWindow.isVisibleAtomic ?? false
        }
        keyboardMonitor.isNavigationActive = { [weak self] in
            self?.suggestionWindow.isSelectionActiveAtomic ?? false
        }
    }

    /// Central key-event router.
    private func handleKeyEvent(_ event: KeyboardEvent) {
        guard settings.isEnabled else { return }
        guard !secureInputDetector.isSecureInputActive else {
            suggestionWindow.hide()
            return
        }
        guard !appIgnoreList.isCurrentAppIgnored else {
            suggestionWindow.hide()
            return
        }

        switch event {
        case .character(let char):
            lastKeystrokeDate = Date()
            // Digits are handled by .numberSelect when suggestions are visible.
            // If we receive a digit here, suggestions must be hidden — just reset.
            if char.isNumber {
                if suggestionWindow.isVisible {
                    // Suggestions visible but we got .character instead of .numberSelect
                    // (race condition). Treat as number selection.
                    let n = Int(String(char)) ?? 0
                    if (1...3).contains(n), let word = suggestionWindow.suggestion(at: n - 1) {
                        insertSuggestion(word)
                        return
                    }
                }
                suggestionWindow.hide()
                contextManager.reset()
                cancelNextWordMode()
                return
            }
            // If we were in next-word mode and the user starts typing,
            // dismiss next-word suggestions and switch to prefix completion.
            if predictionMode == .nextWord {
                cancelNextWordMode()
                suggestionWindow.hide()
            }
            predictionMode = .prefixCompletion
            contextManager.appendCharacter(char)
            // Nudge the cached cursor position rightward so the suggestion
            // bar tracks horizontally even if the next AX call fails.
            TextInserter.nudgeCachedPosition(by: 1)
            #if DEBUG
            NSLog("[TypeBoost] character '\(char)' → currentWord='\(contextManager.currentWord)'")
            #endif
            generateAndShowSuggestions()

        case .backspace:
            lastKeystrokeDate = Date()
            if predictionMode == .nextWord {
                cancelNextWordMode()
                suggestionWindow.hide()
            }
            predictionMode = .prefixCompletion
            TextInserter.nudgeCachedPosition(by: -1)
            contextManager.deleteLastCharacter()
            if contextManager.currentWord.isEmpty {
                suggestionWindow.hide()
            } else {
                generateAndShowSuggestions()
            }

        case .space, .punctuation:
            lastKeystrokeDate = Date()
            // Space/punctuation nudge the cursor forward by 1 character.
            TextInserter.nudgeCachedPosition(by: 1)
            let completedWord = contextManager.currentWord
            let previousWords = contextManager.typingContext.previousWords

            // Record bigram transition for context learning.
            if let prev = previousWords.last, !completedWord.isEmpty {
                predictionEngine.recordWordTransition(
                    previous: prev,
                    current: completedWord
                )

                // Record trigram transition if we have enough context.
                if previousWords.count >= 2 {
                    let secondLast = previousWords[previousWords.count - 2]
                    predictionEngine.recordTrigramTransition(
                        w1: secondLast, w2: prev, next: completedWord
                    )
                }
            }

            // Record manual entry for user dictionary learning.
            if !completedWord.isEmpty {
                predictionEngine.recordManualEntry(completedWord)
            }

            contextManager.commitCurrentWord()

            // Trigger next-word prediction after space if we have context.
            if !contextManager.typingContext.previousWords.isEmpty {
                predictionMode = .nextWord
                generateNextWordSuggestions()
            } else {
                suggestionWindow.hide()
            }

        case .escape:
            cancelNextWordMode()
            predictionMode = .prefixCompletion
            contextManager.cancelCurrentWord()
            suggestionWindow.hide()

        case .arrowUp:
            if !suggestionWindow.isVisible {
                // ↑ activates suggestion mode if suggestions exist.
                if !contextManager.currentWord.isEmpty {
                    generateAndShowSuggestions(activateSelection: true)
                }
            } else {
                suggestionWindow.activateSelection()
            }

        case .arrowDown:
            // ↓ dismisses suggestions so cursor moves normally.
            if suggestionWindow.isVisible {
                suggestionWindow.hide()
                cancelNextWordMode()
                predictionMode = .prefixCompletion
            }

        case .arrowLeft:
            if suggestionWindow.isSelectionActive {
                suggestionWindow.movePrevious()
            } else {
                suggestionWindow.hide()
                cancelNextWordMode()
                predictionMode = .prefixCompletion
                scheduleWordUnderCursorCheck()
            }

        case .arrowRight:
            if suggestionWindow.isSelectionActive {
                suggestionWindow.moveNext()
            } else {
                suggestionWindow.hide()
                cancelNextWordMode()
                predictionMode = .prefixCompletion
                scheduleWordUnderCursorCheck()
            }

        case .enter:
            if suggestionWindow.isSelectionActive,
               let selected = suggestionWindow.acceptSelection() {
                insertSuggestion(selected)
            } else {
                // Line break — nudge bar down by one line height, commit word, hide bar.
                TextInserter.nudgeCachedPositionForNewLine()
                if !contextManager.currentWord.isEmpty {
                    predictionEngine.recordManualEntry(contextManager.currentWord)
                }
                contextManager.commitCurrentWord()
                cancelNextWordMode()
                suggestionWindow.hide()
            }

        case .numberSelect(let n):
            // Quick-select via plain 1/2/3 when suggestions are visible.
            // Supported in all prediction modes: prefixCompletion, nextWord, spellCorrection.
            // Use isVisibleAtomic as the authoritative check — the AppKit isVisible property
            // can lag one run-loop cycle behind the atomic flag on a cold show().
            guard suggestionWindow.isVisibleAtomic, (1...3).contains(n) else { return }
            if let word = suggestionWindow.suggestion(at: n - 1) {
                insertSuggestion(word)
            }

        case .scroll:
            // Scroll fires at 50–100Hz — apply 100ms throttle so we only fire
            // one reposition per continuous scroll gesture, not one per event.
            guard suggestionWindow.isVisible else { return }
            let now = Date()
            guard now.timeIntervalSince(lastScrollDate) > 0.1 else { return }
            lastScrollDate = now
            asyncRepositionBar(fromPoll: true)

        case .mouseDown:
            // Mouse button pressed — may be the start of a window drag.
            // Suppress async reposition until the button is released so the bar
            // doesn't teleport to stale cached coordinates mid-drag.
            isMouseButtonDown = true

        case .mouseUp:
            // Mouse button released — clear drag suppression flag.
            isMouseButtonDown = false
            // User clicked — cursor moved to a new position. Invalidate the
            // position cache and reset shadow typing state so stale context
            // from before the click doesn't produce wrong suggestions.
            TextInserter.invalidateCursorCache()
            contextManager.reset()
            predictionEngine.reset()
            cancelNextWordMode()
            suggestionWindow.hide()
            // Delay long enough for macOS AX to flush the new window geometry
            // after a potential drag. 50ms was too short — AX could still return
            // pre-drag coordinates, producing a ghost bar on the first keystroke.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.checkWordUnderCursor()
            }

        case .other:
            break
        }
    }

    // MARK: – Async Bar Reposition

    /// Fire-and-forget: queries the accurate cursor position (JS injection for browsers,
    /// AX for native apps) on a background thread and repositions the bar when done.
    /// Safe to call on every keystroke — the task is cheap if JS is unavailable (AX only).
    ///
    /// - Parameter fromPoll: When true the bar uses `repositionIfNearby` which hides
    ///   on large jumps (> 150pt) — preventing the bar teleporting to a stale position
    ///   after the user drags a window. Keystroke-triggered calls pass false and always
    ///   reposition unconditionally.
    fileprivate func asyncRepositionBar(fromPoll: Bool = false) {
        // Suppress while mouse is held (window drag) or a task is already in flight.
        // Multiple callers — AXObserver, poll timer, keystroke — can all fire within
        // the same 50ms window. Allowing them to all spawn concurrent Tasks results in
        // multiple simultaneous AX queries that race each other to set the window origin,
        // saturating the AX daemon and generating redundant WindowServer compositing work.
        guard !isMouseButtonDown, !isRepositionInFlight else { return }
        isRepositionInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let bundleID = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            }
            let rect = await TextInserter.accurateCursorRect(bundleID: bundleID)
            await MainActor.run { [weak self] in
                guard let self else {  return }
                self.isRepositionInFlight = false
                guard self.suggestionWindow.isVisible else { return }
                if fromPoll {
                    self.suggestionWindow.repositionIfNearby(near: rect)
                } else {
                    self.suggestionWindow.reposition(near: rect)
                }
            }
        }
    }

    /// Start (or restart) the re-anchor poll. Fires at 300ms while the bar is
    /// actively moving; backs off to 1s after 3 consecutive static ticks to
    /// reduce WindowServer compositing load when the bar is idle.
    /// The timer self-cancels when the bar hides.
    private func startRepositionPolling() {
        repositionPollTimer?.invalidate()
        staticPollCount = 0
        scheduleNextPoll()
    }

    private func scheduleNextPoll() {
        // 300ms while moving; 1s once the bar has been static for 3+ ticks.
        let interval: TimeInterval = staticPollCount >= 3 ? 1.0 : 0.3
        repositionPollTimer?.invalidate()
        repositionPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.suggestionWindow.isVisible else {
                self?.repositionPollTimer?.invalidate()
                self?.repositionPollTimer = nil
                return
            }
            // Skip when a keystroke fired recently — it already triggered asyncRepositionBar().
            guard Date().timeIntervalSince(self.lastKeystrokeDate) > 0.2 else {
                // A keystroke just fired — reset static count and stay at 300ms.
                self.staticPollCount = 0
                self.scheduleNextPoll()
                return
            }
            let prevOrigin = self.suggestionWindow.frame.origin
            self.asyncRepositionBar(fromPoll: true)
            // Check after a short settle whether the bar actually moved.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                let moved = self.suggestionWindow.frame.origin != prevOrigin
                self.staticPollCount = moved ? 0 : self.staticPollCount + 1
                self.scheduleNextPoll()
            }
        }
    }

    // MARK: – Prediction

    private func generateAndShowSuggestions(activateSelection: Bool = false) {
        let context = contextManager.typingContext
        guard !context.currentWord.isEmpty else {
            #if DEBUG
            NSLog("[TypeBoost] generateAndShow: currentWord is empty, hiding")
            #endif
            suggestionWindow.hide()
            return
        }

        // Respect Escape suppression — don't show suggestions after cancel.
        guard !contextManager.isCancelled else { return }

        #if DEBUG
        NSLog("[TypeBoost] generateAndShow: prefix='\(context.currentWord)'")
        #endif
        let suggestions = predictionEngine.predict(context: context)
        #if DEBUG
        NSLog("[TypeBoost] generateAndShow: got \(suggestions.count) suggestions: \(suggestions.map(\.word))")
        #endif
        guard !suggestions.isEmpty else {
            suggestionWindow.hide()
            return
        }

        // Show instantly at the best available position so the bar appears
        // with zero perceived latency. Priority:
        //   1. Nudge-tracked cached rect  — most recent, no AX call needed
        //   2. fastCursorRect()           — tight 20ms AX call, correct on cold-start
        //   3. Mouse location             — last resort, asyncRepositionBar() corrects it
        let instantRect = TextInserter.trackedCursorRect()
            ?? TextInserter.fastCursorRect()
            ?? NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 2, height: 16)
        #if DEBUG
        NSLog("[TypeBoost] generateAndShow: instantRect=\(instantRect)")
        #endif
        suggestionWindow.show(
            suggestions: suggestions,
            near: instantRect,
            activateSelection: activateSelection
        )
        asyncRepositionBar()
        // Reset static count so poll stays at 300ms while typing.
        staticPollCount = 0
        startRepositionPolling()
    }

    // MARK: – Text Insertion

    private func insertSuggestion(_ suggestion: Suggestion) {
        switch predictionMode {
        case .nextWord:
            // No partial word to delete. Use CGEvent keystroke simulation
            // (replaceCurrent with partialLength 0) rather than insertAtCursor,
            // which relies on kAXSelectedTextAttribute — only writable in a handful
            // of apps. CGEvent simulation works universally.
            TextInserter.replaceCurrent(partialLength: 0, replacement: suggestion.word + " ")
            predictionEngine.recordAcceptance(suggestion)
            contextManager.acceptSuggestion(suggestion.word)
            cancelNextWordMode()
            // Chain: immediately show next-word predictions for the word just inserted.
            // The context now includes this word as the last previous word, so the
            // bigram model can suggest what typically follows it.
            TextInserter.invalidateCursorCache()
            predictionMode = .nextWord
            generateNextWordSuggestions()
            return  // skip the hide() + prefixCompletion reset below

        case .prefixCompletion:
            // Replace the partial prefix.
            let partialLength = contextManager.currentWord.count
            TextInserter.replaceCurrent(
                partialLength: partialLength,
                replacement: suggestion.word + " "
            )
            predictionEngine.recordAcceptance(suggestion)
            contextManager.acceptSuggestion(suggestion.word)

        case .spellCorrection:
            // Replace the entire word under the cursor.
            if let word = contextManager.wordUnderCursor() {
                TextInserter.replaceWord(
                    wordLength: word.count,
                    replacement: suggestion.word
                )
                predictionEngine.learnWord(suggestion.word)
            }
        }

        // After inserting a suggestion the cursor has jumped — invalidate
        // the cached position so the next AX query gets a fresh read.
        TextInserter.invalidateCursorCache()
        predictionMode = .prefixCompletion
        suggestionWindow.hide()
    }

    // MARK: – Next-Word Prediction

    private func generateNextWordSuggestions() {
        let context = contextManager.typingContext

        // Get instant suggestions from the bigram model.
        let instantSuggestions = predictionEngine.predictNextWord(context: context)

        if instantSuggestions.isEmpty {
            // No context signal strong enough — don't show empty bar.
            suggestionWindow.hide()
            predictionMode = .prefixCompletion
            return
        }

        let cursorRect = TextInserter.trackedCursorRect()
            ?? TextInserter.fastCursorRect()
            ?? NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 2, height: 16)
        suggestionWindow.show(
            suggestions: instantSuggestions,
            near: cursorRect,
            activateSelection: true,
            mode: .nextWord
        )
        asyncRepositionBar()
        startRepositionPolling()

        // Fire async Foundation Models request for better suggestions.
        predictionEngine.predictNextWordAsync(context: context) { [weak self] aiSuggestions in
            guard let self,
                  self.predictionMode == .nextWord,
                  !aiSuggestions.isEmpty,
                  self.suggestionWindow.isVisible else { return }
            // Use tracked position — cursor hasn't moved since the bar appeared.
            let rect = TextInserter.trackedCursorRect() ?? TextInserter.cursorRect()
            self.suggestionWindow.update(
                suggestions: aiSuggestions,
                near: rect
            )
        }

        // Auto-dismiss after 8 seconds of inactivity. 3s was too short — users
        // reading the suggestions and reaching for a number key often missed the window.
        nextWordDismissTimer?.invalidate()
        nextWordDismissTimer = Timer.scheduledTimer(
            withTimeInterval: 8.0,
            repeats: false
        ) { [weak self] _ in
            guard self?.predictionMode == .nextWord else { return }
            self?.suggestionWindow.hide()
            self?.predictionMode = .prefixCompletion
        }
    }

    private func cancelNextWordMode() {
        nextWordDismissTimer?.invalidate()
        nextWordDismissTimer = nil
        predictionEngine.cancelNextWordPrediction()
        if predictionMode == .nextWord {
            predictionMode = .prefixCompletion
        }
    }

    // MARK: – Spell-Check Mode

    /// Debounced check after arrow-key navigation.
    private func scheduleWordUnderCursorCheck() {
        arrowKeyDebounceTimer?.invalidate()
        arrowKeyDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: 0.35, repeats: false
        ) { [weak self] _ in
            self?.checkWordUnderCursor()
        }
    }

    /// Reads the word under the cursor and, if misspelled, shows corrections.
    private func checkWordUnderCursor() {
        guard settings.isEnabled else { return }
        guard !secureInputDetector.isSecureInputActive else { return }
        guard !appIgnoreList.isCurrentAppIgnored else { return }

        guard let word = contextManager.wordUnderCursor(),
              word.count >= 2 else {
            return
        }

        guard predictionEngine.isMisspelled(word) else { return }

        let corrections = predictionEngine.corrections(for: word)
        guard !corrections.isEmpty else { return }

        let suggestions = corrections.prefix(3).enumerated().map { index, correction in
            Suggestion(word: correction, score: 1.0 - Double(index) * 0.1)
        }

        predictionMode = .spellCorrection
        let cursorRect = TextInserter.trackedCursorRect()
            ?? TextInserter.fastCursorRect()
            ?? NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 2, height: 16)
        suggestionWindow.show(
            suggestions: suggestions,
            near: cursorRect,
            mode: .spellCorrection
        )
        asyncRepositionBar()
        startRepositionPolling()
    }

    // MARK: – AXObserver Management

    /// Creates an AXObserver for the given PID and registers for focus-change
    /// notifications on the app element, then immediately observes the currently
    /// focused element for selectedText changes.
    private func setupAXObserver(pid: pid_t) {
        teardownAXObserver()
        guard pid > 0 else { return }

        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallbackFn, &obs) == .success,
              let observer = obs else { return }

        axObserver = observer
        axObserverPID = pid

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Track focus changes so we re-register on the newly focused element.
        AXObserverAddNotification(observer, appElement,
            kAXFocusedUIElementChangedNotification as CFString, selfPtr)

        // Deliver notifications on the main RunLoop.
        CFRunLoopAddSource(CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer), .defaultMode)

        // Register on the element that's currently focused.
        updateAXFocusedElement()
    }

    /// Re-registers kAXSelectedTextChangedNotification on the currently focused
    /// element after a focus change. Called from the AXObserver C callback.
    fileprivate func updateAXFocusedElement() {
        guard let observer = axObserver, axObserverPID > 0 else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Remove notification from previous element.
        if let old = axFocusedElement {
            AXObserverRemoveNotification(observer, old,
                kAXSelectedTextChangedNotification as CFString)
        }

        // Get the newly focused element.
        let appElement = AXUIElementCreateApplication(axObserverPID)
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement,
            kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedObj = focusedRef else {
            axFocusedElement = nil
            return
        }
        let focused = focusedObj as! AXUIElement
        axFocusedElement = focused

        // kAXSelectedTextChangedNotification fires when the caret moves:
        // arrow keys, mouse click, Home/End, Cmd+A, etc.
        AXObserverAddNotification(observer, focused,
            kAXSelectedTextChangedNotification as CFString, selfPtr)
    }

    private func teardownAXObserver() {
        guard let observer = axObserver else { return }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        if let element = axFocusedElement {
            AXObserverRemoveNotification(observer, element,
                kAXSelectedTextChangedNotification as CFString)
        }
        axObserver = nil
        axObserverPID = 0
        axFocusedElement = nil
    }

    // MARK: – App Switching

    private func handleAppSwitch(_ notification: Notification) {
        let newBundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .bundleIdentifier

        // Only reset context when the frontmost app actually changes.
        // didActivateApplicationNotification also fires when the SAME app
        // regains focus (e.g. returning from Spotlight, Notification Center,
        // system dialogs). Those spurious resets wipe bigram context and
        // cause predictions to disappear for several words.
        guard newBundleID != lastActiveBundleID else {
            // Same app re-activated — just dismiss suggestions (cursor may
            // have moved) but preserve typing context.
            suggestionWindow.hide()
            return
        }

        lastActiveBundleID = newBundleID

        // Cancel arrow-key debounce so it doesn't fire in the new app.
        arrowKeyDebounceTimer?.invalidate()
        arrowKeyDebounceTimer = nil

        // Re-register AXObserver for the new app so cursor moves are tracked instantly.
        // Skip when disabled — no reason to attach to AX processes while inert.
        if settings.isEnabled,
           let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication)?.processIdentifier {
            setupAXObserver(pid: pid)
        }

        // Reset cursor position tracking so stale coordinates from the
        // previous app don't pollute the new one.
        TextInserter.lastClickPosition = nil
        TextInserter.lastKnownMousePosition = nil
        TextInserter.invalidateCursorCache()

        // Full context reset on genuine app switch.
        contextManager.reset()
        predictionEngine.reset()
        cancelNextWordMode()
        predictionMode = .prefixCompletion
        suggestionWindow.hide()
    }
}

// MARK: – AXObserver C Callback

/// File-scope C function required by AXObserverCreate.
/// The observer's RunLoop source is added to the main RunLoop in setupAXObserver,
/// so this callback is always delivered on the main thread — no dispatch needed.
private func axObserverCallbackFn(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

    switch notification as String {
    case kAXFocusedUIElementChangedNotification:
        // Text field focus changed — re-register selectedTextChanged on the new element.
        delegate.updateAXFocusedElement()

    case kAXSelectedTextChangedNotification:
        // Caret moved (arrow key, mouse drag, Home/End, etc.).
        // Skip if the bar isn't visible or if a keystroke just fired — the
        // keystroke path already triggered asyncRepositionBar().
        guard delegate.suggestionWindow.isVisible else { return }
        guard Date().timeIntervalSince(delegate.lastKeystrokeDate) > 0.15 else { return }
        delegate.asyncRepositionBar()

    default:
        break
    }
}
