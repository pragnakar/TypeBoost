# TypeBoost — Complete Technical Specification

**Version:** 2.0.0
**Date:** March 2026
**Status:** Implementation reference — sufficient to rebuild from scratch or port to Linux

---

## Table of Contents

1. [Product Overview](#1-product-overview)
2. [Core Behaviour Contract](#2-core-behaviour-contract)
3. [Keyboard Interaction Model](#3-keyboard-interaction-model)
4. [Prediction Modes](#4-prediction-modes)
5. [Suggestion Bar UI](#5-suggestion-bar-ui)
6. [Architecture Overview](#6-architecture-overview)
7. [Component Specifications](#7-component-specifications)
8. [Caret Tracking System](#8-caret-tracking-system)
9. [Text Insertion System](#9-text-insertion-system)
10. [Prediction Engine](#10-prediction-engine)
11. [Context Manager](#11-context-manager)
12. [Threading Model](#12-threading-model)
13. [State Machine](#13-state-machine)
14. [Settings & Persistence](#14-settings--persistence)
15. [Permissions & Security](#15-permissions--security)
16. [Platform Abstractions (macOS vs Linux)](#16-platform-abstractions-macos-vs-linux)
17. [Technology Stack](#17-technology-stack)
18. [File Structure](#18-file-structure)
19. [Build & Distribution](#19-build--distribution)
20. [Performance Targets](#20-performance-targets)
21. [Known Pitfalls & Critical Implementation Notes](#21-known-pitfalls--critical-implementation-notes)

---

## 1. Product Overview

TypeBoost is a system-wide word prediction and autocomplete utility. It runs as a persistent background process, monitors all keyboard input globally, and displays a floating suggestion bar positioned directly below the text cursor showing up to three predicted words at all times while typing.

**Key characteristics:**
- Works in every application simultaneously (text editors, browsers, email, terminals excluded)
- Never takes focus away from the application being typed in
- All prediction is local — no network, no cloud
- Learns from the user's typing patterns over time
- Sub-30ms perceived latency from keystroke to suggestion appearing

---

## 2. Core Behaviour Contract

These invariants must hold at all times:

1. **Focus is never stolen.** The suggestion bar window must never become the key window or main window. The target application always has keyboard focus.

2. **Synthetic keystrokes are invisible to the monitor.** When TypeBoost inserts text via simulated keystrokes, those events must not re-enter the event handler. They are tagged with a magic integer (`0x54425F53594E` — "TB_SYN") and filtered out at the tap level.

3. **Secure input is always respected.** When the OS signals secure input mode (password fields, login prompts), all monitoring stops immediately and the bar hides.

4. **Events pass through by default.** The keyboard monitor only consumes (blocks from reaching the app) a narrow set of navigation keys when the suggestion bar is actively showing. All other events pass through unmodified.

5. **Ignored apps are fully transparent.** When a per-app exclusion is active, TypeBoost behaves as if it doesn't exist — no bar, no state, no interference.

6. **State resets on app switch.** When the frontmost application changes, the typing context (current word, previous words), prediction state, cursor cache, and suggestion bar are all reset.

---

## 3. Keyboard Interaction Model

### 3.1 Events Monitored

The system monitors the following raw input events globally:
- `keyDown` — all key presses
- `flagsChanged` — modifier key changes (used only to filter out modifier-only events)
- `leftMouseDown` — records cursor position for browser caret estimation
- `leftMouseUp` — triggers spell-check word scan after click
- `scrollWheel` — triggers bar reposition after scroll (throttled to 100ms)

### 3.2 Event Classification

Every `keyDown` is classified into one of:

| Class | Trigger |
|-------|---------|
| `character(c)` | Any letter, apostrophe, or hyphen |
| `backspace` | Delete key |
| `space` | Space bar |
| `punctuation` | Any punctuation or symbol character |
| `escape` | Escape key |
| `arrowUp/Down/Left/Right` | Arrow keys |
| `enter` | Return or numpad Enter |
| `numberSelect(n)` | Plain 1, 2, or 3 **when the suggestion bar is visible** |
| `mouseDown` | Left mouse button pressed |
| `mouseUp` | Left mouse button released |
| `scroll` | Scroll wheel / trackpad scroll |
| `other` | Everything else (Tab, function keys, etc.) |

**Key rule for numberSelect:** Plain digit keys 1/2/3 are classified as `numberSelect` only when `areSuggestionsVisible()` returns true. Otherwise they are passed through as `character`. This check happens on the background tap thread and reads an atomic boolean.

**Command key rule:** Any event with the Command modifier is immediately passed through unmodified and not classified.

### 3.3 Event Consumption

The tap decides whether to consume (block) an event before dispatching it to the main thread:

| Event | Consumed when |
|-------|--------------|
| `arrowUp` | Suggestion bar is visible |
| `arrowDown` | Suggestion bar is visible |
| `arrowLeft` | Navigation mode is active (selection highlighted) |
| `arrowRight` | Navigation mode is active |
| `enter` | Navigation mode is active |
| `escape` | Suggestion bar is visible |
| `numberSelect` | Always (only emitted when bar is visible) |
| All others | Never |

### 3.4 User Selection Flow

**Next-word mode (after space):**
- Bar appears with 3 suggestions, first suggestion highlighted
- `1/2/3` — directly inserts the corresponding suggestion
- `←/→` — navigates between suggestions
- `Enter` — inserts the currently highlighted suggestion
- `↓` — dismisses bar, cursor moves normally in app
- Typing any letter — inserts that character, bar switches to prefix mode
- After a selection, bar immediately refreshes with next-word predictions for the just-inserted word (chained prediction)

**Prefix mode (while typing a word):**
- Bar appears when at least 1 character typed and predictions exist
- `↑` — activates selection, highlights first suggestion
- `←/→` — navigates between suggestions (only in selection mode)
- `Enter` — inserts highlighted suggestion (only in selection mode)
- `1/2/3` — directly inserts corresponding suggestion
- `Esc` — dismisses bar for this word; re-appears on next word

**Spell-correction mode (cursor placed on a misspelled word):**
- Triggered ~400ms after mouse click or arrow-key navigation stops
- Bar shows corrections; `1/2/3` or `Enter` replaces the word at cursor
- Only activates if the word is not in dictionary

---

## 4. Prediction Modes

The app maintains an explicit `predictionMode` enum with three states:

### `prefixCompletion`
Active while the user is typing a word (currentWord is non-empty). Predictions are prefix matches boosted by bigram context and user history. On suggestion acceptance: delete the partial word, insert `word + " "`.

### `nextWord`
Active immediately after the user presses space or accepts a suggestion. Predictions are the most likely words to follow the last completed word. On suggestion acceptance: insert `word + " "` (no deletion needed), then immediately re-enter `nextWord` mode with the new word as context (chained prediction). Auto-dismisses after 8 seconds of inactivity.

### `spellCorrection`
Active when the cursor is resting on a word not found in the dictionary. Triggered 400ms after arrow key or mouse movement stops. On acceptance: replace the entire word under the cursor.

---

## 5. Suggestion Bar UI

### 5.1 Window Properties

- `NSPanel` (not `NSWindow`) — allows showing without activating
- Style mask: `.borderless | .nonactivatingPanel`
- Window level: `.popUpMenu` — floats above normal app windows
- `becomesKeyOnlyIfNeeded = false`
- `acceptsMouseMovedEvents = false`
- Content view: `NSVisualEffectView` with `.popover` material, `.withinWindow` blending, `cornerRadius = 8`

### 5.2 Layout

```
┌────────────────────────────────────────┐
│ [⚡] │  word1  ¹ │  word2  ² │  word3  ³ │
└────────────────────────────────────────┘
         ▲
         │  2pt gap
         ┌─ text cursor
```

- Height: 30pt fixed
- Width: computed from pill content (min 80pt)
- Each pill: word label (left, 13pt medium) + shortcut number (top-right, 9pt regular, tertiary colour)
- Separator lines between pills: 1pt wide NSBox
- Mode icon: `⚡` for next-word mode, orange border ring for spell-correction mode
- Highlighted pill: `controlAccentColor` at 25% opacity background

### 5.3 Positioning

Bar is positioned 2pt below the bottom-left of the text cursor rect. Screen-edge clamping prevents the bar from going off-screen.

```
barOrigin.x = cursorRect.minX
barOrigin.y = cursorRect.maxY + 2
```

If the resulting position would push the bar off the right or bottom edge of the screen, clamp to screen bounds.

### 5.4 Visibility State (Thread Safety)

The window maintains two atomic booleans (`OSAllocatedUnfairLock<Bool>`) readable from any thread:
- `isVisibleAtomic` — true when the bar is on screen (set BEFORE `orderFrontRegardless()`)
- `isSelectionActiveAtomic` — true when a suggestion is highlighted

These are the values read by the CGEventTap background thread for event classification.

### 5.5 Show/Hide Behaviour

**Show:** If already visible, update content and reposition synchronously. If hidden, defer layout to next run loop pass (`DispatchQueue.main.async`) to avoid `layoutSubtreeIfNeeded` reentrancy, then fade in over 100ms.

**Hide:** Fade out over 80ms, then `orderOut()`.

**Critical:** Set `isVisibleAtomic = true` BEFORE calling `orderFrontRegardless()`. This ensures the background tap thread sees the correct state even during the fade-in animation.

---

## 6. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  Background Thread                                                    │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  CGEventTap (KeyboardMonitor)                                 │   │
│  │  - Receives all system key/mouse/scroll events                │   │
│  │  - Filters synthetic events (syntheticEventTag)               │   │
│  │  - Classifies to KeyboardEvent enum                           │   │
│  │  - Decides consume/passthrough (reads atomic booleans)        │   │
│  │  - Dispatches to main queue via DispatchQueue.main.async      │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                              │ KeyboardEvent (async to main)
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Main Thread                                                          │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  AppDelegate (central coordinator / state machine)            │   │
│  │                                                               │   │
│  │  handleKeyEvent(event)                                        │   │
│  │    │                                                          │   │
│  │    ├─ Guards: isEnabled? secureInput? ignoredApp?             │   │
│  │    │                                                          │   │
│  │    ├─ ContextManager.appendCharacter / deleteLastCharacter    │   │
│  │    │  / commitCurrentWord / acceptSuggestion / reset          │   │
│  │    │                                                          │   │
│  │    ├─ PredictionEngine.predict / predictNextWord              │   │
│  │    │  / recordAcceptance / recordManualEntry                  │   │
│  │    │                                                          │   │
│  │    ├─ SuggestionBarWindow.show / hide / update                │   │
│  │    │  / activateSelection / movePrevious / moveNext           │   │
│  │    │  / acceptSelection                                       │   │
│  │    │                                                          │   │
│  │    └─ TextInserter.replaceCurrent / replaceWord               │   │
│  │                                                               │   │
│  │  asyncRepositionBar() — async Task reading AX/JS caret pos   │   │
│  │  repositionPollTimer  — 300ms repeating (backs off to 1s)     │   │
│  │  AXObserver           — instant cursor tracking               │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                       │
│  ┌──────────────┐  ┌─────────────────┐  ┌───────────────────────┐  │
│  │ContextManager│  │ PredictionEngine │  │  SuggestionBarWindow  │  │
│  │              │  │  ┌────────────┐  │  │  + SuggestionBarView  │  │
│  │ currentWord  │  │  │TrieEngine  │  │  │  (NSPanel + pills)    │  │
│  │ previousWords│  │  │BigramModel │  │  └───────────────────────┘  │
│  │ typingContext│  │  │UserDiction.│  │                              │
│  └──────────────┘  │  └────────────┘  │  ┌───────────────────────┐  │
│                    └─────────────────┘  │  MenuBarController        │  │
│  ┌──────────────┐                       │  (NSStatusItem + menu)    │  │
│  │TextInserter  │                       └───────────────────────┘  │
│  │(static enum) │  ┌─────────────────┐                              │
│  │- cursor track│  │ AppIgnoreList   │  ┌───────────────────────┐  │
│  │- caret strats│  │ SecureInputDet. │  │  PermissionManager    │  │
│  │- text insert │  │ AppSettings     │  └───────────────────────┘  │
│  └──────────────┘  └─────────────────┘                              │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. Component Specifications

### 7.1 AppDelegate

Central state machine and event router. Owns all subsystems. Key responsibilities:

**State variables:**
```
predictionMode: .prefixCompletion | .nextWord | .spellCorrection
lastActiveBundleID: String?          -- detects real app switches
isMouseButtonDown: Bool              -- suppresses reposition during drag
lastKeystrokeDate: Date              -- skips poll when keystroke just fired
staticPollCount: Int                 -- backs off poll to 1s after 3 static ticks
lastScrollDate: Date                 -- 100ms scroll throttle
axObserver: AXObserver?              -- instant cursor change notifications
axObserverPID: pid_t                 -- which app the observer is attached to
axFocusedElement: AXUIElement?       -- element currently observed for text changes
```

**Key methods:**
- `handleKeyEvent(_:)` — main dispatch for all keyboard events
- `generateAndShowSuggestions(activateSelection:)` — prefix prediction + show bar
- `generateNextWordSuggestions()` — next-word prediction + show bar + start dismiss timer
- `checkWordUnderCursor()` — spell correction trigger (runs after mouseUp/arrow debounce)
- `insertSuggestion(_:)` — inserts word, updates context, chains if nextWord mode
- `asyncRepositionBar(fromPoll:)` — async Task to reposition bar via AX/JS cursor query
- `repositionPollTimer` — 300ms repeating timer; backs off to 1s after 3 static ticks
- `setupAXObserver(pid:)` — installs AXObserver for frontmost app
- `teardownAXObserver()` — removes observer and cleans all state
- `handleAppSwitch(to:)` — resets all state, installs new AXObserver

**Guard chain in handleKeyEvent:**
```
1. settings.isEnabled == true
2. secureInputDetector.isSecureInputActive == false
3. !appIgnoreList.isIgnored(frontmostApp.bundleIdentifier)
→ proceed with event handling
```

### 7.2 KeyboardMonitor

Owns the CGEventTap. Runs on a dedicated background thread with its own CFRunLoop.

**Critical implementation details:**
- Store `tapRunLoop = CFRunLoopGetCurrent()` inside `installTap()` (runs on background thread), NOT in `start()` (runs on main thread). This is the only correct way to target `stop()` at the right RunLoop.
- `stop()` must call `CFRunLoopRemoveSource(tapRunLoop, source, .commonModes)` then `CFRunLoopStop(tapRunLoop)`. Do NOT use `tapThread?.cancel()` — it does not stop a RunLoop that is running `RunLoop.current.run()`.
- Re-enable the tap if it gets disabled by timeout: check for `tapDisabledByTimeout` and `tapDisabledByUserInput` types and call `CGEvent.tapEnable(tap:enable:true)`.
- The C callback must return `nil` to consume an event, or `Unmanaged.passUnretained(event)` to pass it through.

### 7.3 ContextManager

Tracks the shadow state of what is being typed. No AX calls — purely in-memory string manipulation.

**State:**
```
currentWord: String          -- characters typed since last word boundary
previousWords: [String]      -- completed words, newest last (max 20)
isCancelled: Bool            -- Escape was pressed, suppress until next word
```

**Word boundary events:** space, punctuation, suggestion acceptance, app switch.

**Backspace across word boundary:** When `currentWord` is empty and backspace is pressed, pop the last word from `previousWords` back into `currentWord` (the user is editing the previous word).

**Output:** `typingContext: TypingContext` — snapshot of `(currentWord, previousWords)` consumed by PredictionEngine.

### 7.4 PredictionEngine

Combines trie prefix matching with bigram context scoring. Coordinates UserDictionary and BigramModel.

**`predict(context:) -> [Suggestion]` (synchronous, <10ms):**
1. Query TrieEngine for all words with `currentWord` as prefix → scored list
2. For each candidate, add bigram bonus: look up `(lastWord, candidate)` in BigramModel
3. Add user dictionary bonus for frequently-typed/accepted words
4. Sort by composite score, return top 3

**`predictNextWord(context:) -> [Suggestion]` (synchronous, <10ms):**
1. Look up bigram/trigram entries for the last 1–2 completed words
2. Return top 3 by frequency-weighted score

**`predictNextWordAsync(context:, completion:)` (async, optional):**
- Stub for optional AI layer (Foundation Models on macOS 26+)
- On unavailable platforms: immediately calls `completion([])` and returns

**Learning:**
- `recordAcceptance(_:)` — boost bigram weight for `(previousWord, acceptedWord)`, increment user dictionary count
- `recordManualEntry(_:)` — called when user types a complete word without accepting suggestion
- Words manually typed 3+ times added to user dictionary with score boost

**Scoring formula:**
```
score = 0.5 * frequencyScore + 0.35 * bigramScore + 0.15 * userBonus
```

### 7.5 BigramModel

Stores observed `(word1, word2)` bigram counts and `(word1, word2, word3)` trigram counts with temporal decay.

**Storage:** In-memory `[String: [String: Float]]` dictionary. Persisted to disk as JSON, encrypted with AES-256-GCM.

**Temporal decay:** Every N observations, multiply all weights by 0.95 to de-emphasise old patterns.

**Eviction:** When entry count exceeds threshold, remove entries with weight below a minimum floor.

**`reset()`:** Clear all bigrams, trigrams, totals. Re-seed from built-in defaults.

### 7.6 SuggestionBarWindow

`NSPanel` subclass. Contains one `SuggestionBarView` (an `NSVisualEffectView`).

**Selection state machine:**
```
isSelectionActive: Bool     -- a pill is highlighted
selectedIndex: Int          -- which pill (-1 = none)
```

**`show(suggestions:near:activateSelection:mode:)`:**
- If already visible: update content + reposition synchronously (cancel any in-flight fade)
- If hidden: defer to next run-loop pass, then fade in 100ms
- Set `_atomicVisible = true` **before** `orderFrontRegardless()`

**`repositionIfNearby(near:)`:**
- Only called from poll path
- Computes proposed new origin and measures distance from current
- If distance > 150pt: `hide()` (user dragged window, stale coordinates)
- If distance ≤ 150pt and > 0.5pt: move (avoids redundant compositing)
- If distance ≤ 0.5pt: no-op

**`acceptSelection() -> Suggestion?`:**
Returns the highlighted suggestion (or nil), clears selection state.

### 7.7 MenuBarController

`NSStatusItem` with a dropdown `NSMenu`. Menu is rebuilt on every open via `menuNeedsUpdate(_:)`.

**Menu items:**
- Enable/Disable toggle (global)
- "Disable for Current App" / "Enable for Current App" (dynamic label)
- Separator
- "Launch at Login" (checkmark — reads `SMAppService.mainApp.status` as source of truth, never UserDefaults)
- "Reset Learned Data" (calls `predictionEngine.resetAllLearning()` via closure)
- Separator
- Quit TypeBoost

**Launch at Login implementation:**
- Read current state: `SMAppService.mainApp.status == .enabled`
- Toggle: call `try SMAppService.mainApp.register()` or `try SMAppService.mainApp.unregister()`
- On failure: present `NSAlert` explaining the error and pointing to System Settings

---

## 8. Caret Tracking System

The suggestion bar must be positioned directly below the text cursor. Four strategies are tried in order, with progressive fallback.

### 8.1 Strategy Hierarchy

```
1. trackedCursorRect()       — in-memory nudged estimate (0ms, no API calls)
2. fastCursorRect()          — AX query with 20ms timeout (for cold-start)
3. accurateCursorRect()      — full strategy chain (async, uses JS for browsers)
4. fallback                  — mouse cursor position
```

### 8.2 Strategy 1 — AX Caret Bounds

```swift
// Pseudo-code
systemWide = AXUIElementCreateSystemWide()
AXUIElementSetMessagingTimeout(systemWide, timeout)   // 0.1s normal, 0.02s fast
focused = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute)
range = AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute)
rect = AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute, range)
// rect is in CG coordinates (top-left origin) → flip to AppKit (bottom-left origin)
appKitRect.y = primaryScreenHeight - rect.maxY
```

Returns `nil` on timeout or any AX failure.

### 8.3 Strategy 2 — Browser JS Injection

Used when Strategy 1 fails (browser canvas-based editors, cross-origin iframes).

Supported apps (by bundle ID prefix): Safari, Chrome, Edge, Firefox, Arc, Brave, Opera, Orion.

JavaScript injected via NSAppleScript (compiled and cached per bundle ID):
```javascript
(function() {
  // Canvas editors (Google Docs, Notion, etc.)
  var el = document.querySelector(
    '.kix-cursor-caret, .kix-cursor-nativecaretcontainer, ' +
    '.CodeMirror-cursor, .cm-cursor, .cm-cursor-primary, ' +
    '.monaco-editor .cursor'
  );
  if (el) {
    var r = el.getBoundingClientRect();
    if (r.width > 0 || r.height > 0) {
      return JSON.stringify({x: r.left + window.screenX,
                             y: r.top  + window.screenY,
                             h: r.height});
    }
  }
  // Standard DOM selection
  var sel = window.getSelection();
  if (!sel || sel.rangeCount === 0) return null;
  var range = sel.getRangeAt(0).cloneRange();
  range.collapse(true);
  var rect = range.getBoundingClientRect();
  if (rect.width === 0 && rect.height === 0) return null;
  return JSON.stringify({x: rect.left + window.screenX,
                         y: rect.top  + window.screenY,
                         h: rect.height});
})()
```

The returned `{x, y, h}` are in screen coordinates (top-left origin, CSS pixels). Convert:
```
appKitX = x
appKitY = primaryScreenHeight - y - h
```

**Failure tracking:** Each bundle ID tracks consecutive JS failures in UserDefaults with a 24-hour TTL. After 3 failures, JS injection is skipped for that app until the TTL expires.

### 8.4 Strategy 3 — Last Click Position

Uses `lastClickPosition` recorded from the most recent `leftMouseDown` event. Valid for ~2 seconds after a click.

### 8.5 Strategy 4 — Active Window Centre

Queries the frontmost application's window frame via AX and returns the horizontal centre, vertical midpoint.

### 8.6 AXObserver (Instant Cursor Tracking)

Beyond the polling strategies above, an `AXObserver` delivers instant notifications on every cursor move:

```
kAXFocusedUIElementChangedNotification  → re-register selectedText observer on new element
kAXSelectedTextChangedNotification      → reposition bar if visible & keystroke >150ms ago
```

**Setup:** Call `AXObserverCreate(pid, callback)`, register `kAXFocusedUIElementChangedNotification` on the app element, add observer to main RunLoop via `AXObserverGetRunLoopSource`.

**C callback signature:**
```c
void axObserverCallback(AXObserver observer,
                        AXUIElement element,
                        CFStringRef notification,
                        void* refcon) {
  AppDelegate* delegate = (__bridge AppDelegate*)refcon;
  if (notification == kAXFocusedUIElementChangedNotification)
    [delegate updateAXFocusedElement];
  else if (notification == kAXSelectedTextChangedNotification)
    if (delegate.suggestionWindow.isVisible &&
        [NSDate.date timeIntervalSinceDate:delegate.lastKeystrokeDate] > 0.15)
      [delegate asyncRepositionBar];
}
```

The 0.15s guard prevents double-repositioning: keystrokes already trigger `asyncRepositionBar`, so AXObserver notifications that arrive within 150ms of a keystroke are suppressed.

### 8.7 Position Cache + Nudging

After each AX-verified position fix, cache the rect. On subsequent keystrokes:
- Nudge `cachedRect.x += estimatedCharWidth` per character typed
- Nudge `cachedRect.y -= estimatedLineHeight` per newline
- Invalidate cache if cumulative nudge drift > 500pt (line wrap, scroll, etc.)
- Invalidate on: mouse click, app switch, suggestion acceptance

### 8.8 Ghost Bar Prevention

**Problem:** While the user drags a window, AX returns caret coordinates relative to the old window origin. The poll timer can fire mid-drag and reposition the bar to wrong coordinates, creating a "ghost" bar at the pre-drag position.

**Fix:** Set `isMouseButtonDown = true` on `leftMouseDown`, `false` on `leftMouseUp`. `asyncRepositionBar()` returns immediately if `isMouseButtonDown == true`. Post-mouseUp delay: 150ms before resuming spell-check scan (allows macOS AX to flush new window geometry).

---

## 9. Text Insertion System

### 9.1 Prefix Completion (replaceCurrent)

Replaces a partially typed word:
```
1. Post N × Delete keystrokes (where N = partialLength = currentWord.count)
2. Post each character of replacement string as CGEvent keyDown/keyUp
   with keyboardSetUnicodeString (handles non-ASCII)
3. Tag every synthetic event with eventSourceUserData = 0x54425F53594E
```

### 9.2 Next-Word Insertion (replaceCurrent with partialLength: 0)

No deletion needed — cursor is at the start of a new word (after space). Steps 2–3 above only.

**Why not `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)`?**
This AX write API is only implemented by a small subset of apps (TextEdit, some native cocoa fields). It silently fails in browsers, Electron apps, VS Code, Google Docs, etc. CGEvent simulation is universal.

### 9.3 Spell Correction (replaceWord)

Replaces a complete word under the cursor:
```
1. Move to end of word: Option+Right arrow (kVK_RightArrow with .maskAlternate)
2. Select entire word: Option+Shift+Left arrow
3. Post replacement characters via Unicode CGEvent
```

---

## 10. Prediction Engine

### 10.1 TrieEngine

Prefix trie seeded with ~3,000 common English words and their corpus frequencies (stored as a compiled-in Swift array, not a file). Each node stores a character and an optional word-terminal score.

**`wordsWithPrefix(_ prefix: String) -> [(word: String, score: Float)]`**
- Walk trie to the prefix node
- DFS collect all terminal descendants
- Return sorted by score, max 20 candidates

### 10.2 Bigram/Trigram Model

Stored as nested dictionaries:
```swift
bigrams:  [String: [String: Float]]   // bigrams[w1][w2]  = count
trigrams: [String: [String: [String: Float]]]  // trigrams[w1][w2][w3]
bigramTotals:  [String: Float]        // sum of bigrams[w1].values
trigramTotals: [String: [String: Float]]
```

**Scoring a candidate `w2` given context `[..., w1]`:**
```
score = bigrams[w1][w2] / bigramTotals[w1]   (0.0 if missing)
```

**Seeding:** On first launch or after reset, seed with ~200 high-frequency English bigram pairs (hardcoded in `seedDefaults()`).

### 10.3 UserDictionary

```swift
var words: [String: UserWordEntry]
struct UserWordEntry {
    var manualCount: Int      // times typed manually
    var acceptCount: Int      // times accepted as suggestion
    var lastSeen: Date
}
```

**Score bonus:**
```
bonus = min(1.0, (manualCount * 0.1 + acceptCount * 0.2))
```

Words added to trie when `manualCount >= 3`.

### 10.4 Composite Scoring

```swift
func score(word: String, context: TypingContext) -> Float {
    let freq    = trieEngine.score(word)                          // 0.0–1.0
    let bigram  = bigramModel.score(word, given: context.previousWords.last)  // 0.0–1.0
    let user    = userDictionary.bonus(word)                      // 0.0–1.0
    return 0.5 * freq + 0.35 * bigram + 0.15 * user
}
```

---

## 11. Context Manager

```
appendCharacter(c)       → currentWord.append(c)
deleteLastCharacter()    → currentWord.removeLast()
                           if currentWord.isEmpty: pop previousWords → currentWord
commitCurrentWord()      → previousWords.append(currentWord.lowercased()); currentWord = ""
acceptSuggestion(word)   → previousWords.append(word.lowercased()); currentWord = ""
cancelCurrentWord()      → isCancelled = true (until next word boundary)
reset()                  → currentWord = ""; previousWords.removeAll()
```

**`typingContext`** is a value-type snapshot: `TypingContext(currentWord:, previousWords:)`. The prediction engine consumes this snapshot — it never holds a reference to ContextManager.

---

## 12. Threading Model

```
Main thread:
  - All UI (AppKit requirement)
  - All AppDelegate logic (handleKeyEvent, show/hide bar, AX calls)
  - AXObserver callbacks (attached to main RunLoop)
  - ContextManager, PredictionEngine (single-threaded, main only)
  - Timers (repositionPoll, nextWordDismiss, arrowKeyDebounce)

Background thread (KeyboardMonitor):
  - CGEventTap C callback
  - Event classification (translate)
  - Reads isVisibleAtomic, isSelectionActiveAtomic (OSAllocatedUnfairLock)
  - Dispatches KeyboardEvent to main via DispatchQueue.main.async

Swift Concurrency Task (asyncRepositionBar):
  - Runs on cooperative thread pool
  - Calls TextInserter.accurateCursorRect (AX + JS, may block briefly)
  - Posts result back to main actor
```

**Thread-safety rules:**
- `SuggestionBarWindow._atomicVisible` and `._atomicSelectionActive` use `OSAllocatedUnfairLock` — safe to read from any thread
- All other state in AppDelegate is main-thread only
- Never call `DispatchQueue.main.sync` from the tap callback — deadlock risk if main thread is blocked on AX

---

## 13. State Machine

```
                    ┌──────────────────────────────┐
                    │         DISABLED              │
                    │  (settings.isEnabled=false    │
                    │   or secureInput active        │
                    │   or ignored app)              │
                    └─────────────┬────────────────┘
                                  │ enable
                    ┌─────────────▼────────────────┐
              ┌────►│        IDLE                   │◄────────────────┐
              │     │  bar hidden, context empty    │                  │
              │     └────┬──────────────────────────┘                  │
              │          │ letter typed                                 │
              │     ┌────▼──────────────────────────┐                  │
              │     │     PREFIX_TYPING              │                  │
              │     │  currentWord non-empty         │                  │
              │     │  bar may or may not be showing │                  │
              │     └────┬──────┬────────────────────┘                  │
              │          │space │ suggestion accepted                    │
              │          │      │                                        │
              │     ┌────▼──────▼────────────────────┐                  │
              │     │     NEXT_WORD                   │                  │
              │     │  bar showing predictions        │──8s timer──────►│
              │     │  for what comes after last word │                  │
              │     └────┬──────────────────────────-─┘                  │
              │          │ letter typed (non-number)                     │
              │          └──────────────────────────────────────────────►│
              │                                                           │
              │     ┌──────────────────────────────┐                     │
              └─────│   SPELL_CORRECTION            │─────────────────────┘
                    │  bar showing word corrections  │
                    │  (triggered by mouse/arrow)    │
                    └──────────────────────────────┘
```

---

## 14. Settings & Persistence

### 14.1 AppSettings (UserDefaults)

```swift
struct AppSettings: Codable {
    var isEnabled: Bool = true
    var launchAtLogin: Bool = false         // DISPLAY ONLY — actual state from SMAppService
    var ignoredBundleIDs: [String] = [...]  // Published via Combine for reactive updates
}
```

Default ignored bundle IDs: `com.apple.Terminal`, `com.googlecode.iterm2`, `com.agilebits.onepassword7`, `org.keepassxc.keepassxc`, `com.lastpass.LastPass`, `com.bitwarden.desktop`.

### 14.2 BigramModel Persistence

Saved to `~/Library/Application Support/TypeBoost/bigram_model.json` (encrypted). Loaded at launch via `predictionEngine.loadBigramModel()`. Saved incrementally: every 25 new observations. Save is triggered asynchronously to avoid blocking the typing path.

### 14.3 UserDictionary Persistence

Saved to `~/Library/Application Support/TypeBoost/user_dictionary.json` (encrypted).

### 14.4 Encryption

All persisted data encrypted with AES-256-GCM using a device-specific key stored in the macOS Keychain under the service name `com.typeboost.app`. Key generated on first launch, retrieved on subsequent launches.

---

## 15. Permissions & Security

### 15.1 Required Permissions (macOS)

| Permission | Purpose | TCC Service |
|-----------|---------|-------------|
| Accessibility | Read cursor position (AX API), read focused element | `Accessibility` |
| Input Monitoring | Global CGEventTap for keyboard monitoring | `ListenEvent` |

**Checking:** `AXIsProcessTrusted()` for Accessibility. Input Monitoring has no direct API check — infer from CGEventTap creation success.

**Requesting:** Open `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` via `NSWorkspace.shared.open()`. Cannot be requested programmatically — user must grant manually.

### 15.2 Secure Input Detection

`IsSecureEventInputEnabled()` (Carbon) returns true when a password field or secure prompt is active. Poll every 2 seconds on a background timer. When true: disable tap (but do not stop the tap thread — it's re-enabled when secure input ends).

### 15.3 No Sandbox

TypeBoost **cannot** run in the macOS app sandbox. CGEventTap requires the `com.apple.security.temporary-exception.mach-lookup.global-name` entitlement or simply no sandbox. Distribute as a signed DMG, not through the App Store.

---

## 16. Platform Abstractions (macOS vs Linux)

The app has five platform-specific subsystems. Everything else (ContextManager, PredictionEngine, BigramModel, UserDictionary, TrieEngine, scoring logic) is pure logic with no platform dependencies.

### 16.1 Global Keyboard Monitoring

| macOS | Linux |
|-------|-------|
| `CGEventTap` via `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap)` | `evdev` — read raw events from `/dev/input/eventN` (requires `input` group membership or `udev` rule), or `libinput` for higher-level access |
| Runs on background thread with `CFRunLoop` | Runs on background thread with a blocking `read()` loop on the evdev fd |
| Event types: `CGEventType.keyDown`, `.leftMouseDown`, etc. | Event types: `EV_KEY` with key codes from `linux/input-event-codes.h` |
| Key codes from Carbon (`kVK_*`) | Key codes: `KEY_SPACE=57`, `KEY_BACKSPACE=14`, `KEY_ESC=1`, `KEY_RETURN=28`, `KEY_LEFT=105`, `KEY_RIGHT=106`, `KEY_UP=103`, `KEY_DOWN=108` |
| Can consume events (return nil from callback) | Use `EVIOCGRAB` ioctl to take exclusive ownership of device, re-inject with `/dev/uinput` to pass-through |
| Synthetic event tag via `eventSourceUserData` | Add a custom property to uinput re-injected events, or use a separate uinput device for synthetic events and filter by source device fd |

**Linux event loop example:**
```c
// Open device
int fd = open("/dev/input/event0", O_RDONLY);
ioctl(fd, EVIOCGRAB, 1);  // grab for consumption capability

// Read loop (background thread)
struct input_event ev;
while (read(fd, &ev, sizeof(ev)) > 0) {
    if (ev.type == EV_KEY && ev.value == 1) { // key down
        handleKeyCode(ev.code);
    }
}
```

### 16.2 Cursor Position (Caret Tracking)

| macOS | Linux |
|-------|-------|
| `AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute, range)` | AT-SPI2 (Assistive Technology Service Provider Interface) — the Linux accessibility stack |
| `AXObserver` for instant change notifications | `AT-SPI2` event listeners: `object:text-caret-moved` and `object:state-changed:focused` |

**Linux AT-SPI2 caret position:**
```python
# Python equivalent (use from C via libatspi)
import pyatspi
registry = pyatspi.Registry
desktop = registry.getDesktop(0)
# Find focused text element
obj = pyatspi.findDescendant(desktop, lambda x: x.getState().contains(pyatspi.STATE_FOCUSED))
text = obj.queryText()
offset = text.caretOffset
rect = text.getCharacterExtents(offset, pyatspi.DESKTOP_COORDS)
# rect = (x, y, width, height) in screen coordinates
```

For browser caret: same JavaScript injection approach, but injected via `wmctrl`/`xdotool` or a browser extension rather than AppleScript.

**Fallback (X11):** Query mouse position via `XQueryPointer`, use as approximate caret location.
**Fallback (Wayland):** `wlr-screencopy` or compositor-specific protocols; mouse position via `libinput`.

### 16.3 Text Insertion

| macOS | Linux (X11) | Linux (Wayland) |
|-------|------------|-----------------|
| CGEvent keystroke simulation: `CGEvent(keyboardEventSource:, virtualKey:0, keyDown:true)` + `keyboardSetUnicodeString` | `XSendEvent` with `XKeyEvent` or `xdotool type --clearmodifiers "word"` | `wtype "word"` (wlroots) or `ydotool type "word"` |
| Tagged with `eventSourceUserData` | Tagged with a custom `XClientMessageEvent` sentinel, or use a separate X client for injection | Use separate Wayland client identity |

**Linux X11 insertion via xdo:**
```c
xdo_t* xdo = xdo_new(NULL);
xdo_type(xdo, CURRENTWINDOW, "word ", XDO_DELAY_DEFAULT);
```

Or via `XSendEvent` directly:
```c
XKeyEvent ke = { .type = KeyPress, .display = dpy, .window = focused, ... };
XSendEvent(dpy, focused, True, KeyPressMask, (XEvent*)&ke);
```

### 16.4 Floating Window (Suggestion Bar)

| macOS | Linux |
|-------|-------|
| `NSPanel` with `.borderless | .nonactivatingPanel`, window level `.popUpMenu` | X11: `override_redirect = True` window, `_NET_WM_WINDOW_TYPE_TOOLTIP` or `_NET_WM_STATE_ABOVE` |
| `NSVisualEffectView` with `.popover` material | GTK4 `GtkPopover` or a custom composited `GtkWindow` with blur via KWin/Picom |
| Positioned via `NSWindow.setFrameOrigin(_:)` | Positioned via `XMoveWindow(dpy, win, x, y)` or `gtk_window_move()` |
| Non-activating: automatic with `nonactivatingPanel` | Set `_NET_WM_STATE_SKIP_TASKBAR`, `_NET_WM_STATE_SKIP_PAGER`, handle focus carefully |

**Wayland:** Use layer-shell protocol (`wlr-layer-shell` or `xdg-output` + `xdg-popup`) for always-on-top non-activating overlay windows.

### 16.5 Launch at Login

| macOS | Linux |
|-------|-------|
| `SMAppService.mainApp.register()` / `.unregister()` | Systemd user service: `~/.config/systemd/user/typeboost.service` with `WantedBy=default.target`; enable/disable via `systemctl --user enable/disable typeboost` |
| Status via `SMAppService.mainApp.status == .enabled` | Status via `systemctl --user is-enabled typeboost` |

### 16.6 Permissions

| macOS | Linux |
|-------|-------|
| Accessibility: System Settings → Privacy | AT-SPI2: enabled by default on GNOME/KDE with accessibility features on |
| Input Monitoring: System Settings → Privacy | evdev: add user to `input` group, or use polkit rule. Udev rule: `KERNEL=="event*", SUBSYSTEM=="input", MODE="0660", GROUP="input"` |
| Checked via `AXIsProcessTrusted()` | Checked by attempting to open `/dev/input/eventN` — EACCES means no permission |

---

## 17. Technology Stack

### macOS (current implementation)

| Component | Technology |
|-----------|-----------|
| Language | Swift 5.9+ |
| Minimum OS | macOS 13.0 (Ventura) |
| UI Framework | AppKit (bar, menu bar) + SwiftUI (settings) |
| Keyboard Monitoring | CoreGraphics CGEventTap |
| Cursor Tracking | AXUIElement (Accessibility API) + AXObserver |
| Browser Caret | NSAppleScript → JavaScript injection |
| Text Insertion | CGEvent unicode keystroke simulation |
| Tray Icon | NSStatusBar / NSStatusItem |
| Login Item | SMAppService (macOS 13+) |
| Reactive State | Combine (publishers for settings changes) |
| Concurrency | Swift Concurrency (async/await) + DispatchQueue |
| Thread Safety | OSAllocatedUnfairLock |
| Persistence | Codable JSON + UserDefaults |
| Encryption | CryptoKit AES-256-GCM |
| Project Gen | XcodeGen |

### Linux (recommended port stack)

| Component | Technology |
|-----------|-----------|
| Language | Rust (preferred) or C++ |
| UI Framework | GTK4 with layer-shell for overlay, or Qt6 |
| Keyboard Monitoring | evdev (`/dev/input/eventN`) via tokio-evdev (Rust) |
| Event Injection | uinput (`/dev/uinput`) for pass-through |
| Cursor Tracking | AT-SPI2 via atspi-rs (Rust) |
| Browser Caret | WebDriver / browser extension (no AppleScript equivalent) |
| Text Insertion | `wtype`/`xdotool` subprocess, or `atspi-atspi_generate_keyboard_event` |
| Tray Icon | `libappindicator3` or StatusNotifierItem D-Bus protocol |
| Login Item | systemd user service |
| Concurrency | tokio async runtime (Rust) |
| Persistence | JSON via serde_json |
| Encryption | AES-256-GCM via ring or RustCrypto |

---

## 18. File Structure

```
TypeBoost/
├── project.yml                         # XcodeGen spec
├── SPECIFICATION.md                    # This document
├── Build_Log.md                        # Chronological change log
├── TypeBoost.dmg                       # Latest distributable
├── TypeBoost/
│   ├── Info.plist
│   ├── TypeBoost.entitlements          # No sandbox; Accessibility exception
│   ├── App/
│   │   ├── TypeBoostApp.swift          # NSApplicationMain entry, sets activation policy .accessory
│   │   └── AppDelegate.swift           # Central coordinator + state machine (~850 lines)
│   ├── Core/
│   │   ├── KeyboardMonitor.swift       # CGEventTap on background thread
│   │   ├── ContextManager.swift        # Shadow typing state (currentWord, previousWords)
│   │   ├── TextInserter.swift          # Caret tracking (4 strategies) + text insertion
│   │   └── PermissionManager.swift     # AXIsProcessTrusted + Input Monitoring check
│   ├── Prediction/
│   │   ├── PredictionEngine.swift      # Orchestrates trie + bigram + user dict
│   │   ├── TrieEngine.swift            # Prefix trie with frequency scores
│   │   ├── BigramModel.swift           # Bigram/trigram model with decay + persistence
│   │   ├── UserDictionary.swift        # Per-user learned words
│   │   ├── FrequencyData.swift         # ~3000 English words with corpus frequencies
│   │   └── FoundationModelEngine.swift # Stub for optional Apple FM layer
│   ├── UI/
│   │   ├── SuggestionBarWindow.swift   # NSPanel, positioning, atomic visibility
│   │   ├── SuggestionBarView.swift     # NSVisualEffectView with 3 pills + separators
│   │   ├── MenuBarController.swift     # NSStatusItem + NSMenu builder
│   │   └── SettingsView.swift          # SwiftUI settings panel
│   ├── Models/
│   │   └── AppSettings.swift           # Codable settings + Combine @Published
│   └── Services/
│       ├── SecureInputDetector.swift   # IsSecureEventInputEnabled() polling
│       ├── AppIgnoreList.swift         # Per-app exclusion with Combine publisher
│       └── StorageService.swift        # Encrypted JSON file I/O
├── TypeBoostTests/
│   ├── TrieEngineTests.swift
│   ├── ContextManagerTests.swift
│   └── PredictionEngineTests.swift
└── Scripts/
    ├── setup.sh                        # Generate .xcodeproj via XcodeGen
    ├── build.sh                        # xcodebuild CLI wrapper
    ├── archive.sh                      # Signed archive for distribution
    ├── create_dmg.sh                   # Package .app into TypeBoost.dmg
    └── reinstall.sh                    # Full reinstall: reset perms, rebuild, install, launch
```

---

## 19. Build & Distribution

```bash
# 1. Generate Xcode project
./Scripts/setup.sh

# 2. Build Release
./Scripts/build.sh release

# 3. Full reinstall (development)
./Scripts/reinstall.sh
# - One admin password prompt
# - Resets TCC permissions (tccutil reset Accessibility + ListenEvent com.typeboost.app)
# - Removes /Applications/TypeBoost.app
# - Builds fresh Release binary
# - Creates TypeBoost.dmg at project root
# - Installs from DMG to /Applications
# - Launches app

# 4. Distribution build
./Scripts/archive.sh "Developer ID Application: <name> (<team>)"
./Scripts/create_dmg.sh
xcrun notarytool submit TypeBoost.dmg --apple-id <id> --team-id <team> --wait
xcrun stapler staple TypeBoost.dmg
```

**Bundle ID:** `com.typeboost.app`
**Minimum macOS:** 13.0 (Ventura)
**Architecture:** Universal (arm64 + x86_64)
**Sandbox:** Disabled (required for CGEventTap)
**Hardened Runtime:** Yes (required for notarization)

---

## 20. Performance Targets

| Metric | Target | Implementation note |
|--------|--------|---------------------|
| Keystroke → suggestion appears | < 30ms | TrieEngine query <5ms; bar show <10ms |
| TrieEngine prefix query | < 5ms | Trie depth O(prefix length); 3000 words trivial |
| BigramModel lookup | < 2ms | Hash map O(1) |
| AX caret query (cold) | < 100ms | Timeout set to 100ms via `AXUIElementSetMessagingTimeout` |
| AX caret query (fast path) | < 20ms | `fastCursorRect()` timeout set to 20ms |
| Memory (steady state) | < 60MB | BigramModel + trie fit in ~5MB |
| CPU while typing | < 5% | All sync prediction <10ms; AX async |
| CPU idle | < 1% | Poll timer backs off to 1s after 3 static ticks |
| Poll timer interval | 300ms active, 1s backed off | Static count threshold: 3 ticks |

---

## 21. Known Pitfalls & Critical Implementation Notes

These are non-obvious issues discovered during implementation. A rebuild that misses these will have identical bugs.

### 21.1 CGEventTap RunLoop Bug

**Problem:** Calling `CFRunLoopGetCurrent()` inside `stop()` (which runs on the main thread) returns the main RunLoop, not the tap thread's RunLoop. `CFRunLoopRemoveSource` on the wrong RunLoop is a no-op, and the background thread runs forever with an orphaned source. On re-enable, a second tap is created while the first is still alive, causing duplicate event delivery.

**Fix:** Store `tapRunLoop = CFRunLoopGetCurrent()` inside `installTap()`, which executes on the background thread. Use this stored reference in `stop()`.

### 21.2 isVisibleAtomic Must Be Set Before orderFrontRegardless

**Problem:** The CGEventTap callback fires on a background thread and reads `isVisibleAtomic` to decide whether to emit `numberSelect`. If `_atomicVisible` is set after `orderFrontRegardless()`, there is a window where the bar is animating in but `isVisibleAtomic = false` — the next key press emits `.character` instead of `.numberSelect`, cancelling the next-word bar.

**Fix:** Set `_atomicVisible.withLock { $0 = true }` before `orderFrontRegardless()`.

### 21.3 Text Insertion Must Use CGEvent, Not AX Set Value

**Problem:** `AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute, text)` only works in native Cocoa text fields. It silently fails in browsers, Electron apps, VS Code, terminal emulators, Google Docs, and most modern apps.

**Fix:** Always use CGEvent unicode keystroke simulation (`keyboardSetUnicodeString`) for text insertion in all modes.

### 21.4 Backspace Across Word Boundary

**Problem:** After accepting "hippopotamus " (with trailing space), pressing backspace should reopen "hippopotamus" for editing, not lose the word. If ContextManager doesn't handle this, the shadow state desynchronises from actual text.

**Fix:** When `currentWord.isEmpty` and backspace is pressed, pop the last word from `previousWords` back into `currentWord`.

### 21.5 Per-App Disable Must Reset All State

**Problem:** Disabling TypeBoost for the current app and re-enabling it leaves stale `contextManager`, `predictionMode`, cursor cache, and suggestion bar state from before the pause. The bar may reappear in the wrong position or show suggestions for the wrong word.

**Fix:** Subscribe to `appIgnoreList.$ignoredBundleIDs` via Combine. On both disable and enable: reset `contextManager`, `predictionEngine`, cancel next-word mode, set `predictionMode = .prefixCompletion`, invalidate cursor cache, hide bar.

### 21.6 Launch at Login Source of Truth

**Problem:** Using UserDefaults as source of truth for Launch at Login means any silent failure of `SMAppService.register()` leaves the checkbox showing the wrong state.

**Fix:** Read `SMAppService.mainApp.status == .enabled` directly in the menu builder. Show `NSAlert` on `register()`/`unregister()` failure.

### 21.7 Ghost Bar During Window Drag

**Problem:** While dragging a window, AX queries return caret coordinates relative to the pre-drag window origin. The poll timer repositions the bar to the wrong position.

**Fix:** Track `isMouseButtonDown`. Return immediately from `asyncRepositionBar()` when `isMouseButtonDown == true`. Wait 150ms after mouseUp before resuming.

### 21.8 AX Coordinate System

macOS uses two coordinate systems:
- **AppKit / NSWindow:** origin at bottom-left of primary screen, Y increases upward
- **CoreGraphics / AX / JavaScript:** origin at top-left, Y increases downward

Every AX rect must be converted:
```swift
appKitY = NSScreen.screens.first!.frame.height - cgRect.maxY
```

Using `NSScreen.main` instead of `NSScreen.screens.first` gives wrong results on multi-display setups where the primary display is not the main display.

### 21.9 Synthetic Event Loop

**Problem:** TypeBoost inserts text via simulated keystrokes. If those keystrokes are not filtered, they re-enter the tap callback and trigger prediction for the characters being inserted — causing infinite loops or corrupted state.

**Fix:** Set `event.setIntegerValueField(.eventSourceUserData, value: 0x54425F53594E)` on every synthetic CGEvent. In the tap callback, check this field first and pass through immediately if it matches.

### 21.10 JS Injection Failure Tracking

**Problem:** Repeatedly calling AppleScript for JS injection on apps that don't support it (non-browser Electron apps, apps with CSP) adds latency silently.

**Fix:** Track consecutive failures per bundle ID in UserDefaults with a 24-hour TTL. Skip JS injection after 3 failures until TTL expires.

### 21.11 WindowServer Crash on Screen Sleep (Watchdog Timeout)

**Problem:** After extended idle or screen sleep, macOS WindowServer can crash with bug type 409 ("monitoring timed out") if TypeBoost's main thread is unresponsive for 40+ seconds. Root cause: `NSAppleScript` JS injection calls (on the `appleScriptSerial` queue) can block indefinitely when targeting suspended/sleeping browser processes. Combined with AXObserver notification bursts on wake, this can back up main-thread work beyond the WindowServer watchdog threshold.

**Symptom:** `"indicator":"monitoring timed out for service"`, `"details":"WindowServer main thread unresponsive for 40 seconds"`, `"displayState":"OFF"` in crash report. Restarting TypeBoost immediately resolves it.

**Fix:** Subscribe to four sleep/wake notifications and suspend/resume all monitoring:

```swift
// In applicationDidFinishLaunching:
let wsCenter = NSWorkspace.shared.notificationCenter
wsCenter.publisher(for: NSWorkspace.willSleepNotification)
    .sink { [weak self] _ in self?.suspendForSleep() }.store(in: &cancellables)
wsCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
    .sink { [weak self] _ in self?.suspendForSleep() }.store(in: &cancellables)
wsCenter.publisher(for: NSWorkspace.didWakeNotification)
    .sink { [weak self] _ in self?.resumeAfterWake() }.store(in: &cancellables)
wsCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
    .sink { [weak self] _ in self?.resumeAfterWake() }.store(in: &cancellables)

func suspendForSleep() {
    repositionPollTimer?.invalidate(); repositionPollTimer = nil
    teardownAXObserver()
    keyboardMonitor.stop()
    suggestionWindow.hide()
    contextManager.reset(); predictionEngine.reset()
    cancelNextWordMode(); predictionMode = .prefixCompletion
    TextInserter.invalidateCursorCache()
}

func resumeAfterWake() {
    // 1-second delay: lets AX subsystem and all apps finish restoring window state
    // before we re-attach the AXObserver — prevents an immediate burst of stale notifications.
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
```

### 21.12 Next-Word Mode: activateSelection Must Be True

**Problem:** If `generateNextWordSuggestions()` calls `show(suggestions:near:activateSelection:false)`, then `isSelectionActiveAtomic` is never set. The CGEventTap callback guards `numberSelect` emission on `isNavigationActive()` which reads `isSelectionActiveAtomic`. With it false, digit keys are never classified as `numberSelect` — they fall through as `character` events and dismiss the bar. Arrow keys also dismiss because `isSelectionActive == false` in the arrowLeft/arrowRight handlers.

**Fix:** Always pass `activateSelection: true` when calling `show()` for next-word predictions. This ensures the first suggestion is highlighted immediately and digit/arrow keys work from the moment the bar appears.

### 21.13 Chained Next-Word Prediction After Selection

**Problem:** After the user selects a next-word suggestion, the inserted word becomes the new "last word" in context. Showing no predictions after insertion leaves the user with no guidance for the following word, breaking the natural flow.

**Fix:** After inserting a next-word suggestion in `insertSuggestion(_:)`, do not hide the bar or reset to prefixCompletion. Instead:

```swift
case .nextWord:
    TextInserter.replaceCurrent(partialLength: 0, replacement: suggestion.word + " ")
    predictionEngine.recordAcceptance(suggestion)
    contextManager.acceptSuggestion(suggestion.word)  // appends word to previousWords
    cancelNextWordMode()                               // clears dismiss timer
    TextInserter.invalidateCursorCache()
    predictionMode = .nextWord
    generateNextWordSuggestions()                      // immediately show next predictions
    return  // skip the hide() + prefixCompletion reset below
```

The context manager's `acceptSuggestion` moves the inserted word into `previousWords`, so `predictNextWord(context:)` has the correct bigram context for the chain.

---