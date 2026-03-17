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
    private var suggestionWindow: SuggestionBarWindow!
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
    private var lastKeystrokeDate: Date = .distantPast
    /// Consecutive poll ticks where the bar didn't move. After 3 static ticks
    /// the poll interval backs off to 1s to reduce WindowServer compositing work.
    private var staticPollCount: Int = 0

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

        // Re-check permissions when app becomes active.
        // Track the initial frontmost app so the first notification
        // doesn't spuriously reset context.
        lastActiveBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .sink { [weak self] notification in self?.handleAppSwitch(notification) }
        .store(in: &cancellables)

        // Observe enable/disable toggle from settings.
        settings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled && self.permissionManager.hasRequiredPermissions {
                    self.keyboardMonitor.start()
                    // Reset all transient state — user may have typed in another
                    // app or moved the cursor while TypeBoost was disabled, so
                    // pre-disable context, prediction mode, and cursor cache are stale.
                    self.contextManager.reset()
                    self.predictionEngine.reset()
                    self.cancelNextWordMode()
                    TextInserter.invalidateCursorCache()
                } else {
                    self.keyboardMonitor.stop()
                    self.suggestionWindow.hide()
                }
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboardMonitor.stop()
        predictionEngine.saveBigramModel()
        settings.save()
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
            guard suggestionWindow.isVisible, (1...3).contains(n) else { return }
            if let word = suggestionWindow.suggestion(at: n - 1) {
                insertSuggestion(word)
            }

        case .mouseUp:
            // User clicked — cursor moved to a new position. Invalidate the
            // position cache and reset shadow typing state so stale context
            // from before the click doesn't produce wrong suggestions.
            TextInserter.invalidateCursorCache()
            contextManager.reset()
            predictionEngine.reset()
            cancelNextWordMode()
            suggestionWindow.hide()
            // Check for misspelled word after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
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
    private func asyncRepositionBar(fromPoll: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            let bundleID = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            }
            let rect = await TextInserter.accurateCursorRect(bundleID: bundleID)
            await MainActor.run { [weak self] in
                guard let self, self.suggestionWindow.isVisible else { return }
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

        // Show instantly at the best available cached position so the bar
        // appears with zero latency, then fire an async AX query to reposition
        // accurately. This runs on the main actor but deferred, so the current
        // keystroke handler returns before the AX call blocks.
        let instantRect = TextInserter.trackedCursorRect()
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
            // No partial word to delete — just insert at cursor.
            TextInserter.insertAtCursor(suggestion.word + " ")
            predictionEngine.recordAcceptance(suggestion)
            contextManager.acceptSuggestion(suggestion.word)
            cancelNextWordMode()

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
            ?? NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 2, height: 16)
        suggestionWindow.show(
            suggestions: instantSuggestions,
            near: cursorRect,
            activateSelection: false,
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

        // Auto-dismiss after 3 seconds of inactivity.
        nextWordDismissTimer?.invalidate()
        nextWordDismissTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0,
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
            ?? NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 2, height: 16)
        suggestionWindow.show(
            suggestions: suggestions,
            near: cursorRect,
            mode: .spellCorrection
        )
        asyncRepositionBar()
        startRepositionPolling()
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
