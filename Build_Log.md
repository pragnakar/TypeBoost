# TypeBoost — Build Log

Complete history of all development work performed across all sessions.

---

## Session 1: Project Setup & Core Architecture

### 1. Entry Point Fix (`main.swift`)
- Created `main.swift` as the app entry point since the project uses a custom `AppDelegate` rather than `@main`
- Configured `NSApplication.shared.delegate = AppDelegate()` and `NSApp.run()`

### 2. Permission Management (`PermissionManager.swift`)
- Implemented Accessibility and Input Monitoring permission checks
- Added `isAccessibilityGranted`, `isInputMonitoringGranted`, `hasRequiredPermissions`
- Added `requestPermissions()` to prompt users via System Settings

### 3. Keyboard Monitor (`KeyboardMonitor.swift`)
- Built global `CGEventTap` with `.defaultTap` to intercept keyboard and mouse events
- Defined `KeyboardEvent` enum: `.character`, `.backspace`, `.space`, `.punctuation`, `.escape`, `.arrowUp/Down/Left/Right`, `.enter`, `.numberSelect`, `.mouseUp`, `.other`
- Closures for `areSuggestionsVisible` and `isNavigationActive` to conditionally consume events

### 4. Context Manager (`ContextManager.swift`)
- Tracks `currentWord` (partially typed) and `previousWords` (up to 20 completed words)
- `TypingContext` struct snapshot consumed by PredictionEngine
- Methods: `appendCharacter`, `deleteLastCharacter`, `commitCurrentWord`, `acceptSuggestion`, `cancelCurrentWord`, `reset`

### 5. Trie Engine (later replaced)
- Initial prediction engine using a Trie data structure with frequency data
- Loaded ~30k common English words with frequency scores

### 6. Suggestion Bar UI
- `SuggestionBarWindow` — borderless, non-activating `NSPanel` at popup-menu window level
- `SuggestionBarView` — `NSVisualEffectView` with up to 3 `SuggestionPillView` children
- Fade-in/out animations, keyboard selection (arrow keys + Enter), number quick-select (1/2/3)

### 7. Menu Bar Controller (`MenuBarController.swift`)
- Status-item menu with enable/disable toggle, per-app ignore list, user dictionary management

### 8. App Delegate (`AppDelegate.swift`)
- Central coordinator wiring all subsystems together
- `handleKeyEvent` router dispatching to context manager → prediction engine → UI

### 9. Secure Input Detector (`SecureInputDetector.swift`)
- Detects password fields via `IsSecureEventInputEnabled()` to pause suggestions

### 10. App Ignore List (`AppIgnoreList.swift`)
- Per-app exclusion using bundle identifiers

### 11. App Settings (`AppSettings.swift`)
- Persistent settings with `@Published` properties for reactive UI binding

### 12. Storage Service (`StorageService.swift`)
- File helpers for Application Support directory
- AES-256-GCM encryption via CryptoKit with device-specific key derivation

### 13. User Dictionary (`UserDictionary.swift`)
- Learns from typing patterns: manual entries, suggestion acceptances, ignores
- Scoring with logarithmic scaling and ignore penalization
- JSON persistence with debounced saves

---

## Session 2: UX Polish, Browser Fix, Foundation Models

### 14. Suggestion Bar Positioning
- 4-level cascading strategy for cursor position detection:
  1. **AX Caret Bounds** — precise for native apps
  2. **Browser/Electron Window + Click Anchor** — handles hidden iframes
  3. **Last Mouse Click Position** — fallback anchor
  4. **Active Window Centre** — last resort
- Coordinate conversion: AX top-left origin → AppKit bottom-left origin
- Per-app browser/Electron bundle ID lists for strategy selection
- Hard clamp to visible screen area to prevent off-screen panels

### 15. Pill Layout Polish
- Proper intrinsic width calculation per pill
- Separator positioning between pills
- Selection highlight with accent color

### 16. Foundation Model Integration (`FoundationModelEngine.swift`)
- `ContextualPredictionProvider` protocol for abstraction
- `StubContextualProvider` for macOS < 26
- `FoundationModelEngine` using `LanguageModelSession` with temperature 0.3
- Guardrail violation tracking with consecutive hit limit (5 max)
- `ContextualProviderFactory` for runtime selection

### 17. Prediction Engine (`PredictionEngine.swift`)
- Layer 1: NSSpellChecker completions (synchronous, <10ms)
- Layer 1b: BigramModel contextual re-ranking
- Layer 1c: UserDictionary personalization boost
- Layer 2: Foundation Models async refinement with caching
- Blended scoring: 50% rank + 35% context + 15% user bonus

### 18. Bigram Model (`BigramModel.swift`)
- Dictionary-based bigram/trigram storage
- Seeded with ~100 common English word pairs
- `score(candidate:previousWords:)` with trigram/bigram blend (60/40)

---

## Session 3: Spell Correction, Next-Word Prediction, Recommendations

### 19. Replace Trie with NSSpellChecker (`SpellCheckerEngine.swift`)
- Deleted `TrieEngine.swift` and `FrequencyData.swift`
- Created `SpellCheckerEngine` wrapping `NSSpellChecker`:
  - `completions(for:limit:)` — prefix completions from 170k+ words
  - `isMisspelled(_:)` — spell checking
  - `corrections(for:)` — guesses + correction for misspelled words
  - `learnWord(_:)` / `unlearnWord(_:)` — custom dictionary

### 20. Spell-Check Mode
- Arrow-key navigation triggers debounced `checkWordUnderCursor()` (0.35s)
- Mouse click triggers `checkWordUnderCursor()` after 50ms delay
- `wordUnderCursor()` in ContextManager reads word at cursor via AX API
- Orange border on suggestion bar in spell-correction mode
- Replaces entire word under cursor when correction accepted

### 21. Layout Recursion Fix
- **Problem**: `SuggestionBarView.update()` called `window.setFrame()` during `layout()`, causing "It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out"
- **Solution**: Separated into 3 phases:
  1. `update()` — configure pill content only, set `needsLayout = true`
  2. `layout()` override — position pills within current bounds only
  3. `resizeWindowToFitContent()` — deferred via `DispatchQueue.main.async`

### 22. Next-Word Prediction Feature
- **PredictionMode enum**: `.prefixCompletion`, `.nextWord`, `.spellCorrection`
- **BigramModel additions**:
  - `topNextWords(after:limit:)` — bigram lookup
  - `topNextWords(afterPair:and:limit:)` — trigram lookup
- **PredictionEngine additions**:
  - `predictNextWord(context:)` — synchronous bigram-based predictions
  - `predictNextWordAsync(context:completion:)` — async FM refinement
  - `cancelNextWordPrediction()` — cancels pending FM task
- **FoundationModelEngine addition**:
  - `predictNextWord(context:)` — sends last 6 words, temperature 0.2, max 3 tokens
- **TextInserter addition**:
  - `insertAtCursor(_:)` — inserts text without deleting (for next-word mode)
- **SuggestionBarView**:
  - `prefixIconView` — ⚡ icon for next-word mode
  - `configure(word:shortcut:)` — optional shortcut (nil hides number hint)
- **SuggestionBarWindow**:
  - `.nextWord` suggestion mode
  - `update(suggestions:near:mode:)` — async in-place refresh
- **AppDelegate flow**:
  - Space/punctuation triggers bigram instant results + async FM request
  - 3-second auto-dismiss timer
  - `cancelNextWordMode()` cleanup
  - `insertSuggestion()` handles all 3 modes

### 23. Test Updates
- Deleted `TrieEngineTests.swift`
- Created `SpellCheckerEngineTests.swift` — 12 tests covering completions, spell checking, corrections, learning, performance
- Updated `PredictionEngineTests.swift` — added `testIsMisspelled()`, `testCorrections()`
- All 33 tests passing

---

## Session 4: Code Quality Improvements

### 24. Debug Logging Cleanup
- Wrapped all 13+ `NSLog` calls in `#if DEBUG` across:
  - `AppDelegate.swift` — keystroke logging, cursor rect, suggestions
  - `PredictionEngine.swift` — init message
  - `FoundationModelEngine.swift` — availability messages
  - `UserDictionary.swift` — load/save error messages
- Prevents sensitive keystroke data from appearing in production logs

### 25. Safe AX API Unwraps
- **TextInserter.swift**: Changed all `as! AXUIElement` and `as! AXValue` force-unwraps to use nil-check-then-cast pattern (`guard let obj = ref else { return }; let element = obj as! AXUIElement`)
- **ContextManager.swift**: Same pattern applied to `wordUnderCursor()` method
- Note: CF types require `as!` (compiler rejects `as?` for CoreFoundation types), but the nil check before the cast ensures safety

### 26. UserDictionary Save Debounce
- Reduced from 5 seconds to 1 second for more responsive persistence
- Ensures recently learned words survive unexpected app termination

### 27. SuggestionBarWindow Async Ordering Fix
- **Problem**: `SuggestionBarView.update()` and `SuggestionBarWindow.show()` each scheduled separate `DispatchQueue.main.async` blocks, creating a race condition
- **Solution**: View's `update()` no longer resizes the window. Window's `show()` calls `resizeWindowToFitContent()` + `positionPanel()` in a single async block
- Made `resizeWindowToFitContent()` internal visibility so window can call it
- Same fix applied to `update(suggestions:near:mode:)`

### 28. Foundation Models Timeout
- Added 4-second timeout to both Layer 2 prediction and next-word prediction async tasks
- Implemented `withTimeout(seconds:operation:)` helper using `TaskGroup`
- Prevents UI from waiting indefinitely if FM hangs

### 29. BigramModel Eviction Policy
- Added `maxContextKeys = 5000` cap
- `evictBigramsIfNeeded()` — removes lowest-count context keys when cap exceeded
- `evictTrigramsIfNeeded()` — same for trigrams
- Called after each `recordBigram` and `recordTrigram`
- Prevents unbounded memory growth over long sessions

### 30. BigramModel JSON Serialization
- Replaced tab-separated text format with proper JSON using `Codable`
- `SerializedModel` struct with `bigrams` and `trigrams` dictionaries
- `serialise()` → JSON encoding, `deserialise()` → JSON decoding
- Backwards-compatible: `deserialiseLegacy()` still reads old tab-separated format
- Eliminates parsing ambiguity from words containing tab characters

### 31. Foundation Model Guardrail Error Handling
- **Problem**: `predictNextWord` catch block used `"\(error)".contains("guardrailViolation")` — fragile string matching
- **Solution**: Replaced with proper typed error catching:
  ```swift
  catch let error as LanguageModelSession.GenerationError {
      switch error {
      case .guardrailViolation: consecutiveGuardrailHits += 1
      default: break
      }
  }
  ```

### 32. SuggestionPillView Intrinsic Width Cache
- **Problem**: `intrinsicWidth` recalculated text size on every access (during layout)
- **Solution**: Added `cachedIntrinsicWidth` property, recomputed only in `configure(word:shortcut:)` when the word actually changes
- Eliminates redundant `NSString.size(withAttributes:)` calls during layout passes

### 33. StorageService & UserDictionary Force-Unwrap Fixes
- **StorageService.swift**: Changed `FileManager.default.urls(...).first!` to safe `guard let ... else { return temporaryDirectory fallback }`
- **UserDictionary.swift**: Same pattern — falls back to temporary directory if Application Support is unavailable

---

## Session 5: Async Cursor Tracking & Browser Positioning Overhaul

### 34. Cursor Position Cache (`TextInserter.swift`)
- Added `cachedCursorRect`, `cachedCursorTimestamp`, `cachedCursorBundleID` for position caching
- `nudgeCachedPosition(by:)` — moves cache horizontally on each keystroke (+1 char, -1 backspace) without calling AX
- `trackedCursorRect()` — returns cached position if < 5s old; nil forces a fresh AX query
- `invalidateCursorCache()` — clears all cache state (called on app switch, mouse click, suggestion accept)
- `estimatedCharWidth` — dynamically learned via EMA from consecutive AX reads (80/20 smoothing)
- Coordinate flip helpers updated to always use `NSScreen.screens.first` (primary screen) for correct multi-display behaviour

### 35. ContextManager Backspace-Past-Word-Boundary (`ContextManager.swift`)
- `deleteLastCharacter()` now reopens the previous word when `currentWord` is empty
- Backspacing past a space/punctuation boundary pops the last entry from `previousWords` back into `currentWord`, keeping shadow state in sync with on-screen text

### 36. Async AX Reposition (`AppDelegate.swift`, `SuggestionBarWindow.swift`)
- Added `reposition(near:)` to `SuggestionBarWindow` — repositions without changing suggestions
- All three show paths (`generateAndShowSuggestions`, `generateNextWordSuggestions`, `checkWordUnderCursor`) now:
  1. Show bar instantly at cached/mouse position (zero latency)
  2. Fire `asyncRepositionBar()` — deferred task that gets accurate position and repositions
- `asyncRepositionBar()` helper extracted to avoid duplicating the Task + guard pattern

### 37. Shadow State Re-sync on Mouse Click (`AppDelegate.swift`)
- `.mouseUp` handler now calls `contextManager.reset()` + `cancelNextWordMode()` + `suggestionWindow.hide()`
- Prevents stale typing context from before the click producing wrong suggestions after cursor repositioning

### 38. BigramModel Eviction Optimisation (`BigramModel.swift`)
- Added `bigramObservationsSinceEviction` and `trigramObservationsSinceEviction` counters
- O(n log n) eviction sort now runs at most once every 500 observations instead of on every single `recordBigram`/`recordTrigram` call
- `evictionCheckInterval = 500` constant

### 39. JavaScript Injection via osascript (`TextInserter.swift`)
- **Root cause addressed**: Chrome/Edge AX returns garbage or (0,0) for web content; `window.screenX/Y + getBoundingClientRect()` gives pixel-perfect caret coordinates
- `caretJS` — minified single-line JS using single-quote string literals (safe to embed in AppleScript double-quoted strings)
- `chromiumAppNames` — bundle ID → AppleScript app name mapping for Chrome, Edge, Brave, Arc, Opera, Vivaldi
- `jsInjectionDisabled: Set<String>` — remembers browsers where osascript returned non-zero (user hasn't enabled "Allow JavaScript from Apple Events"); skips future attempts to avoid overhead
- `jsCaretRect(bundleID:primaryScreenHeight:)` — pure function, safe on background thread; spawns `osascript` via `Process` with multiple `-e` arguments; parses JSON `{x, y, h}`; converts JS screen-space (top-left origin) to AppKit (bottom-left origin)
- `accurateCursorRect(bundleID:)` — async method: reads screen height on main actor, dispatches JS to background thread via `withCheckedContinuation`, updates cache on main actor, falls back to synchronous AX cascade

### 40. AX Messaging Timeout (`TextInserter.swift`)
- `AXUIElementSetMessagingTimeout(..., 0.1)` added to:
  - `systemWide` element in `strategy1_axCaretBounds`
  - `focused` element in `strategy1_axCaretBounds`
  - `appElement` in `strategy2_browserPosition`
  - `appElement` in `strategy4_activeWindowCentre`
- AX calls now bail in 100ms instead of blocking indefinitely in Chrome/Edge

### 41. Enter-Key Vertical Nudge (`TextInserter.swift`, `AppDelegate.swift`)
- `estimatedLineHeight` static var (default 20pt) — learned via EMA from AX caret rect height and Y delta between consecutive reads
- `nudgeCachedPositionForNewLine()` — decrements cache Y by `estimatedLineHeight`, resets horizontal drift counter, increments `linesTypedSinceLastClick`
- `linesTypedSinceLastClick` resets to 0 on `invalidateCursorCache()` and on every successful AX re-anchor
- `.enter` case in `handleKeyEvent` now nudges position + commits current word + hides bar when not accepting a suggestion

### 42. Re-Anchor Poll Timer (`AppDelegate.swift`)
- `repositionPollTimer: Timer?` — repeating 300ms timer started whenever the suggestion bar is shown
- Calls `asyncRepositionBar()` on each tick, keeping the bar accurate after scroll, browser layout reflow, or auto-indent without needing a keystroke
- Self-cancels when `suggestionWindow.isVisible` is false — no explicit cleanup required on hide paths

### 43. Vertical Drift in Strategy 2 Fallback (`TextInserter.swift`)
- `strategy2_browserPosition()` now offsets the last click Y by `linesTypedSinceLastClick × estimatedLineHeight`
- AppKit Y decreases going down, so drift subtracts from the original click Y
- Result clamped to `windowFrame.minY + 4` to prevent going off-screen
- Bar now tracks roughly correct vertical position even when AX and JS are both unavailable

---

## Session 6: JavaScript Injection Hardening & Browser UX Polish

### 44. NSAppleScript Compiled + Cached (`TextInserter.swift`)
- Replaced `Process`/`osascript` subprocess with `NSAppleScript` executed on a dedicated serial `DispatchQueue` (`com.typeBoost.appleScript`)
- `compiledScript(for:)` builds and compiles the AppleScript source once per browser bundle ID, storing it in `compiledScripts: [String: NSAppleScript]`; subsequent calls reuse the compiled bytecode
- Eliminated ~30–50ms process fork/exec overhead per call — JS caret lookups now take ~5–10ms
- Serial queue ensures NSAppleScript is never called concurrently (prevents run-loop conflicts)

### 45. Native Form Control Detection via JS (`TextInserter.swift`)
- `caretJS` now returns the sentinel `'native'` when `document.activeElement` is `<input>`, `<textarea>`, or `<select>`
- Swift treats `'native'` as a clean fallback signal (not a failure) — silently falls through to AX strategy1 which works correctly for these elements
- Previously, focusing a search box or login form returned `'null'` from `getSelection()`, which was miscounted toward the JS failure limit and could disable JS injection for the whole browser session

### 46. CSS `lineHeight` in JS Payload (`TextInserter.swift`)
- `caretJS` now reads `window.getComputedStyle(el).lineHeight` and uses it as the `h` field
- More reliable than `getBoundingClientRect().height` of a collapsed caret, which is 0 or 1 in many editors (Gmail, Notion, Twitter)
- JS-derived line height feeds back into `estimatedLineHeight` via EMA (80/20) on every successful call, improving vertical nudge accuracy for Enter-key tracking and Strategy 2 drift

### 47. 3-Strike Failure Tolerance (`TextInserter.swift`)
- Replaced `jsInjectionDisabled: Set<String>` with `jsFailureCount: [String: Int]` and `maxJSFailures = 3`
- Only real AppleScript execution errors (setting disabled, browser not responding) increment the counter
- `'null'` (no selection) and `'native'` (form control) returns do NOT count as failures
- A successful call resets the counter to 0, so a transient Chrome hiccup at cold start no longer permanently disables JS injection for the session

### 48. Skip Poll During Rapid Typing (`AppDelegate.swift`)
- Added `lastKeystrokeDate: Date` property, stamped on every `.character`, `.backspace`, `.space`, and `.punctuation` event
- The 300ms `repositionPollTimer` now skips `asyncRepositionBar()` if a keystroke fired within the last 200ms — the keystroke already triggered it
- Poll fires only during idle periods (no typing), where its value is catching position drift from browser scroll, layout reflow, or auto-indent — not duplicating keystroke work

---

## Session 7: Google Docs Cursor Fix

### 49. Google Docs `.kix-cursor-caret` Support (`TextInserter.swift`)
- **Problem**: Google Docs is a canvas-based editor — `window.getSelection()` always returns `rangeCount === 0`, causing `caretJS` to return `'null'` and fall through to the unreliable AX strategy. Bar positioned far from caret.
- **Fix**: `caretJS` now queries `.kix-cursor-caret` (Google Docs' internal cursor DOM element) before the `getSelection()` path. The element has a valid `getBoundingClientRect()` even though the browser selection API is empty.

### 50. CodeMirror + Monaco Canvas-Editor Support (`TextInserter.swift`)
- Same root cause as Google Docs: these editors render in a canvas/custom layer and don't expose a real browser selection
- Added three more DOM cursor selectors to `caretJS`, tried in order before `getSelection()`:
  - `.CodeMirror-cursor` — CodeMirror 5 (Overleaf, GitHub web editor, Replit, many coding sites)
  - `.cm-cursor` — CodeMirror 6 (Obsidian web, newer Replit)
  - `.monaco-editor .cursor` — Monaco Editor (vscode.dev, StackBlitz, CodeSandbox)
- Refactored `caretJS` to use a `fromEl(e)` helper function inside the IIFE — eliminates repeated `getBoundingClientRect` + coord conversion code for each selector

### 51. `jsFailureCount` Persisted to UserDefaults with 24-hour TTL (`TextInserter.swift`)
- **Problem**: Failure count was in-memory only. If "Allow JavaScript from Apple Events" was off at first launch, the browser hit 3 failures and JS stayed disabled for the whole session — even after enabling the setting, user had to restart TypeBoost.
- **Fix**: `jsFailureCount` initialised from UserDefaults at launch, filtered to discard entries older than 24 hours
- `persistJSFailureCount(for:)` helper writes updated count + timestamp to `TypeBoost.jsFailureCount` / `TypeBoost.jsFailureCountDate` keys after every increment and every reset
- A successful JS call resets count to 0 and persists immediately, so re-enabling the browser setting takes full effect on the next app launch without waiting for the TTL

### 52. Window-Drag Bar Teleport Fix (`AppDelegate.swift`, `SuggestionBarWindow.swift`)
- **Problem**: Pausing while bar is visible, then dragging the window caused the bar to jump to a random/wrong position. The 300ms poll fires during/after the drag, JS returns `'null'` (focus left the text), AX falls back to the stale position cache, bar repositions to the pre-drag screen coordinates.
- **Fix**: Distinguished poll-triggered repositions from keystroke-triggered ones via `asyncRepositionBar(fromPoll: Bool)` parameter
- Added `repositionIfNearby(near:)` to `SuggestionBarWindow`: if the proposed position is > 150pt from the current bar position, **hides** the bar instead of teleporting — normal typing only moves the bar a few pixels per character, so a large jump during polling reliably signals a window move or other stale-cache event
- Keystroke path (`asyncRepositionBar(fromPoll: false)`) uses `reposition(near:)` unconditionally — corrections from fresh AX/JS calls always apply
- Poll path (`asyncRepositionBar(fromPoll: true)`) uses `repositionIfNearby(near:)` — hides cleanly on large jumps

---

## Session 8: WindowServer Compositing Optimisation

### 53. Guard `setFrameOrigin` Against No-Op Calls (`SuggestionBarWindow.swift`)
- **Problem**: `positionPanel` called `setFrameOrigin` even when the bar hadn't moved (distance = 0). On a transparent/visual-effect window this always triggers a WindowServer compositing pass — even with the same origin — generating ~200 no-op IPC calls per minute from the 300ms poll.
- **Fix**: Added `guard distance > 0.5 else { return }` before the animate/snap branch. Eliminates all compositing work when the bar is stationary.

### 54. Poll Back-Off When Bar Is Static (`AppDelegate.swift`)
- **Problem**: The 300ms poll fired at a constant rate regardless of whether the bar was actually moving, generating unnecessary WindowServer work during idle periods.
- **Fix**: Replaced the repeating `Timer` with `scheduleNextPoll()` — a one-shot timer that reschedules itself. After 3 consecutive ticks where the bar didn't move (`staticPollCount >= 3`), interval backs off to 1s. Resets to 300ms immediately on any keystroke or position change.

### 55. `setContentSize` Race Fix (`SuggestionBarView.swift`)
- **Problem**: `resizeWindowToFitContent()` checked `window.frame.size != newSize` before dispatching async, but a previous deferred call may have already applied the same size. The stale check let duplicate `setContentSize` calls through, each creating a new IOSurface backing store in WindowServer — the primary cause of gradual memory growth.
- **Fix**: Added a second size check inside the `DispatchQueue.main.async` block to discard redundant calls.

### 56. Switch `NSVisualEffectView` to `.withinWindow` Blending (`SuggestionBarView.swift`)
- **Problem**: `.behindWindow` blending requires WindowServer to maintain a live composited snapshot of everything behind the bar for the blur effect. On every bar move, WindowServer re-samples the content at the new position — the most expensive compositing mode on macOS.
- **Fix**: Changed `blendingMode` from `.behindWindow` to `.withinWindow`. The visual appearance is nearly identical for a floating panel; WindowServer no longer needs to track behind-window content.

---

## Session 9: AXObserver, Scroll Repositioning, Cold-Start Fix

### 57. AXObserver for Instant Cursor Tracking (`AppDelegate.swift`)
- **Problem**: Cursor moves from arrow keys, mouse drag-selection, IME, Home/End were only tracked by the 300ms poll — creating visible lag between cursor position and bar position.
- **Fix**: Added `setupAXObserver(pid:)` / `teardownAXObserver()` / `updateAXFocusedElement()` methods and file-scope C callback `axObserverCallbackFn`. Registers `kAXFocusedUIElementChangedNotification` on the app element and `kAXSelectedTextChangedNotification` on the currently focused text field. On `selectedTextChanged`, calls `asyncRepositionBar()` unless a keystroke fired in the last 150ms (keystroke path already handles it). Observer is set up on `handleAppSwitch` and torn down on `applicationWillTerminate`.

### 58. Scroll Repositioning (`KeyboardMonitor.swift`, `AppDelegate.swift`)
- **Problem**: Scrolling in a document (e.g. in a browser or code editor) moved the text under the cursor without triggering any keystroke event, leaving the bar stranded at a stale position.
- **Fix**: Added `.scroll` to `KeyboardEvent` enum and `.scrollWheel` to the CGEventMask. In `handleKeyEvent`, a 100ms throttle gate fires `asyncRepositionBar(fromPoll: true)` once per scroll gesture.

### 59. Cold-Start Position Fix (`AppDelegate.swift`, `TextInserter.swift`)
- **Problem**: On the first keystroke after cache invalidation, `TextInserter.trackedCursorRect()` returns nil, so the bar appeared at mouse location — then jumped ~50ms later when `asyncRepositionBar()` returned the true position.
- **Fix**: Added `fastCursorRect()` (20ms AX timeout via `strategy1_axCaretBounds(timeout: 0.02)`). All three show sites (`generateAndShowSuggestions`, `generateNextWordSuggestions`, `checkWordUnderCursor`) now use the chain: `trackedCursorRect() ?? fastCursorRect() ?? mouseLocation`. Eliminates the jump on cold-start.

### 60. AXObserver C Callback (`AppDelegate.swift`)
- Added file-scope `axObserverCallbackFn` required by `AXObserverCreate`. Runs on the main RunLoop (delivered synchronously on main thread). Routes `kAXFocusedUIElementChangedNotification` to `updateAXFocusedElement()` and `kAXSelectedTextChangedNotification` to `asyncRepositionBar()` with a 150ms keystroke-recency guard.

---

## Build & Test Status

- **Build**: Successful (0 errors, 0 warnings)
- **Tests**: 33/33 passing
  - ContextManagerTests: 11 tests
  - PredictionEngineTests: 9 tests
  - SpellCheckerEngineTests: 13 tests

---

## Files Modified (Complete List)

| File | Status |
|------|--------|
| `TypeBoost/main.swift` | Created |
| `TypeBoost/App/AppDelegate.swift` | Created + Multiple edits |
| `TypeBoost/Core/KeyboardMonitor.swift` | Created |
| `TypeBoost/Core/ContextManager.swift` | Created + Edits |
| `TypeBoost/Core/TextInserter.swift` | Created + Multiple edits |
| `TypeBoost/Core/PermissionManager.swift` | Created |
| `TypeBoost/Core/SecureInputDetector.swift` | Created |
| `TypeBoost/Core/AppIgnoreList.swift` | Created |
| `TypeBoost/Prediction/SpellCheckerEngine.swift` | Created (replaced TrieEngine) |
| `TypeBoost/Prediction/PredictionEngine.swift` | Created + Multiple edits |
| `TypeBoost/Prediction/BigramModel.swift` | Created + Multiple edits |
| `TypeBoost/Prediction/FoundationModelEngine.swift` | Created + Edits |
| `TypeBoost/Prediction/UserDictionary.swift` | Created + Edits |
| `TypeBoost/UI/SuggestionBarWindow.swift` | Created + Edits |
| `TypeBoost/UI/SuggestionBarView.swift` | Created + Major rewrites |
| `TypeBoost/Services/StorageService.swift` | Created + Edits |
| `TypeBoost/Services/AppSettings.swift` | Created |
| `TypeBoost/UI/MenuBarController.swift` | Created |
| `TypeBoostTests/SpellCheckerEngineTests.swift` | Created |
| `TypeBoostTests/PredictionEngineTests.swift` | Created + Edits |
| `TypeBoostTests/ContextManagerTests.swift` | Created |
| `TypeBoost/Prediction/TrieEngine.swift` | Deleted |
| `TypeBoost/Prediction/FrequencyData.swift` | Deleted |
| `TypeBoostTests/TrieEngineTests.swift` | Deleted |
