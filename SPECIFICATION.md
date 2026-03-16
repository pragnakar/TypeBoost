# TypeBoost — Technical Specification (Redrafted)

**Version:** 1.0.0
**Date:** March 2026
**Status:** Implementation-ready

---

## 1. Overview

TypeBoost is a macOS productivity utility that provides real-time predictive word suggestions while typing on a physical keyboard. It works system-wide across all applications, displaying up to three word completions in a floating suggestion bar near the text cursor.

The app increases typing speed and reduces keystrokes by combining instant prefix-based predictions (Layer 1) with optional on-device AI contextual enhancement (Layer 2, via Apple Foundation Models on macOS 26+).

TypeBoost is a menu-bar-only application with no Dock icon and no main window. All interaction occurs through the floating suggestion bar and the status-bar menu.

---

## 2. Goals

**Primary:** Provide real-time word predictions with sub-30 ms perceived latency, working system-wide across macOS applications.

**Secondary:** Learn from the user's typing patterns to improve prediction quality over time, while keeping all data fully local and encrypted.

---

## 3. Non-Goals (V1)

Grammar correction, full sentence generation, cloud-based prediction, cross-device sync, mobile support, AI writing assistant features.

---

## 4. Suggestion Selection Model

TypeBoost supports two complementary selection mechanisms:

**Primary — Arrow keys + Enter:**
- **↑ (Up Arrow):** Activates suggestion mode and highlights the first suggestion.
- **← → (Left/Right Arrow):** Navigates between suggestions while in selection mode.
- **Enter:** Accepts the highlighted suggestion.
- **Esc:** Dismisses suggestions for the current word.

**Secondary — Option + Number (quick-select):**
- **⌥1 / ⌥2 / ⌥3:** Directly selects suggestion 1, 2, or 3.
- Plain digit keys (1, 2, 3) always type normally — they are never intercepted.

When a suggestion is accepted, TypeBoost deletes the partially-typed word and inserts the completed word followed by a space.

---

## 5. Suggestion Bar UI

A floating, borderless NSPanel positioned below the text cursor. Uses NSVisualEffectView with `.popover` material for native macOS vibrancy. Contains up to three "pill" subviews, each showing the suggested word and an `⌥N` shortcut hint.

**Appears when:** The user types at least one letter of a word and predictions are available.

**Disappears when:** The user completes a word (space/punctuation), presses Escape, the cursor moves away, or the typed character is a digit.

**Escape behaviour:** Dismisses suggestions for the current word only. Suggestions resume automatically when the user starts a new word. If the entire word is deleted and retyped, it is treated as a new word and suggestions reappear.

The panel never becomes key or main, so keyboard focus remains in the target application at all times.

---

## 6. Prediction Architecture

### Layer 1 — Instant Prefix Prediction (synchronous, < 10 ms)

A prefix trie seeded with ~3 000 common English words, combined with:
- **Frequency ranking** — words scored by corpus frequency.
- **Bigram/trigram context** — scores boosted based on preceding words.
- **User dictionary bonus** — scores boosted for words the user types or accepts frequently.

Scoring formula: `Score = α·Frequency + β·Context + γ·UserBonus` where α=0.5, β=0.35, γ=0.15.

### Layer 2 — Apple Foundation Models (asynchronous, optional)

When running on macOS 26+ with Apple Intelligence enabled, TypeBoost dispatches an async request to the on-device LanguageModelSession for contextually richer suggestions. Results are cached per prefix and blended into the next Layer 1 ranking cycle.

If Foundation Models are unavailable, Layer 2 is a no-op stub. The app runs identically on macOS 13+ without it.

---

## 7. User Vocabulary Learning

TypeBoost learns from typing patterns:
- Words typed manually 3+ times are added to the user dictionary.
- Accepted suggestions receive a score boost.
- Repeatedly ignored suggestions receive a score penalty.

Users can disable learning, reset all learned data, or clear the prediction cache via the menu bar.

---

## 8. Secure Input & Application Ignore List

TypeBoost disables itself automatically when:
- macOS secure input mode is active (password fields, system prompts).
- The frontmost application is on the ignore list.

**Default ignored apps:** Terminal, iTerm, 1Password, KeePassXC, LastPass, Bitwarden.

Users can add any application to the ignore list from the menu bar ("Disable for Current App").

---

## 9. Permissions

TypeBoost requires two macOS permissions, both granted via System Settings → Privacy & Security:

1. **Accessibility** — to read cursor position and interact with text fields.
2. **Input Monitoring** — to observe global keyboard events via CGEventTap.

The app detects missing permissions at launch and guides the user to the correct System Settings pane. Permission status is displayed in the menu bar menu and polled every 2 seconds.

**Note:** CGEventTap requires running outside the macOS app sandbox. TypeBoost is distributed as a signed .app in a DMG, not through the Mac App Store.

---

## 10. Technology Stack

| Component | Technology |
|---|---|
| Language | Swift 5.9+ |
| Minimum OS | macOS 13.0 (Ventura) |
| UI Framework | AppKit (suggestion bar, menu bar) + SwiftUI (settings panel) |
| Keyboard Monitoring | Core Graphics CGEventTap |
| Text Interaction | Accessibility API (AXUIElement) |
| Text Insertion | CGEvent keystroke simulation |
| Persistence | Codable JSON files + UserDefaults |
| Encryption | CryptoKit AES-256-GCM |
| Menu Bar | NSStatusBar / NSStatusItem |
| Login Item | SMAppService (macOS 13+) |
| AI (optional) | FoundationModels (macOS 26+) |
| Project Gen | XcodeGen |

---

## 11. Application Architecture

```
┌─────────────────┐
│ CGEventTap       │  (background thread)
│ KeyboardMonitor  │
└────────┬────────┘
         │ KeyboardEvent
         ▼
┌─────────────────┐
│  AppDelegate     │  (main thread — central router)
│                  │
│  ┌─────────────┐ │     ┌──────────────────┐
│  │ContextManager│◄────►│ PredictionEngine  │
│  └─────────────┘ │     │  ├─ TrieEngine    │
│                  │     │  ├─ BigramModel   │
│  ┌─────────────┐ │     │  ├─ UserDictionary│
│  │SecureInput   │ │     │  └─ FM Engine    │
│  │Detector      │ │     └──────────────────┘
│  └─────────────┘ │
│                  │
│  ┌─────────────┐ │     ┌──────────────────┐
│  │AppIgnoreList │ │     │ SuggestionBar    │
│  └─────────────┘ │     │ Window + View    │
│                  │     └──────────────────┘
│  ┌─────────────┐ │
│  │TextInserter  │ │     ┌──────────────────┐
│  └─────────────┘ │     │ MenuBarController │
└─────────────────┘     └──────────────────┘
```

---

## 12. Performance Targets

| Metric | Target |
|---|---|
| Prediction generation (Layer 1) | < 10 ms |
| UI rendering | < 10 ms |
| Total perceived latency | < 30 ms |
| Memory usage (steady state) | < 60 MB |
| CPU during typing | < 5% |
| CPU idle | < 1% |

---

## 13. Privacy

All data processing is local. No network communication. Typing data is never uploaded. Stored data (user dictionary, bigram model) is encrypted with AES-256-GCM using a device-specific key. Users have full control to view, reset, or delete their data.

---

## 14. Build & Distribution

1. **Generate project:** `./Scripts/setup.sh` (requires XcodeGen)
2. **Build:** `./Scripts/build.sh release`
3. **Archive (signed):** `./Scripts/archive.sh "Developer ID Application: ..."`
4. **Package DMG:** `./Scripts/create_dmg.sh`
5. **Notarise:** `xcrun notarytool submit dist/TypeBoost-1.0.0.dmg ...`
6. **Staple:** `xcrun stapler staple dist/TypeBoost-1.0.0.dmg`

---

## 15. File Structure

```
TypeBoost/
├── project.yml                         # XcodeGen spec
├── SPECIFICATION.md                    # This document
├── TypeBoost/
│   ├── Info.plist
│   ├── TypeBoost.entitlements
│   ├── App/
│   │   ├── TypeBoostApp.swift          # Entry point
│   │   └── AppDelegate.swift           # Central coordinator
│   ├── Core/
│   │   ├── KeyboardMonitor.swift       # CGEventTap wrapper
│   │   ├── ContextManager.swift        # Word buffer + context
│   │   ├── TextInserter.swift          # AX-based text replacement
│   │   └── PermissionManager.swift     # Permission checking
│   ├── Prediction/
│   │   ├── PredictionEngine.swift      # Coordinator (Layer 1 + 2)
│   │   ├── TrieEngine.swift            # Prefix trie
│   │   ├── BigramModel.swift           # Bigram/trigram scoring
│   │   ├── UserDictionary.swift        # Learned vocabulary
│   │   ├── FrequencyData.swift         # Built-in word frequencies
│   │   └── FoundationModelEngine.swift # Optional Apple FM layer
│   ├── UI/
│   │   ├── SuggestionBarWindow.swift   # Floating NSPanel
│   │   ├── SuggestionBarView.swift     # Suggestion pill layout
│   │   ├── MenuBarController.swift     # Status-item menu
│   │   └── SettingsView.swift          # SwiftUI preferences
│   ├── Models/
│   │   └── AppSettings.swift           # Persisted settings
│   ├── Services/
│   │   ├── SecureInputDetector.swift   # Password field detection
│   │   ├── AppIgnoreList.swift         # Per-app exclusion
│   │   └── StorageService.swift        # File I/O + encryption
│   └── Resources/
│       └── Assets.xcassets/
├── TypeBoostTests/
│   ├── TrieEngineTests.swift
│   ├── ContextManagerTests.swift
│   └── PredictionEngineTests.swift
└── Scripts/
    ├── setup.sh                        # Generate .xcodeproj
    ├── build.sh                        # CLI build
    ├── archive.sh                      # Signed archive
    └── create_dmg.sh                   # DMG packaging
```
