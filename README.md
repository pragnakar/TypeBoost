<p align="center">
  <img src="TypeBoost_icon.png" alt="TypeBoost" width="128" height="128">
</p>

<h1 align="center">TypeBoost</h1>

<p align="center">
  Real-time predictive word suggestions for macOS — system-wide, on-device, private.
</p>

<p align="center">
  <a href="#installation">Installation</a> · <a href="#how-it-works">How It Works</a> · <a href="#keyboard-shortcuts">Keyboard Shortcuts</a> · <a href="#building-from-source">Build from Source</a>
</p>

---

TypeBoost is a macOS menu-bar utility that provides real-time word predictions while you type on a physical keyboard. It works across all applications — browsers, editors, email clients, Slack, Notion, and more — displaying up to three suggestions in a lightweight floating bar that follows your cursor.

All predictions run entirely on-device. Nothing leaves your machine.

## Installation

### Quick Install (DMG)

1. Download **[TypeBoost.dmg](./TypeBoost.dmg)** from this repository
2. Open the DMG and drag **TypeBoost** to your Applications folder
3. Launch TypeBoost from Applications
4. Grant the two permissions macOS will request:
   - **Accessibility** — needed to read cursor position and insert text
   - **Input Monitoring** — needed to intercept keyboard events
5. TypeBoost appears as a small icon in your menu bar. That's it — start typing.

> **Note:** On first launch, macOS may show a "developer cannot be verified" warning. Right-click the app → Open → click Open again to bypass Gatekeeper.

### Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon or Intel Mac
- Accessibility and Input Monitoring permissions

## How It Works

TypeBoost intercepts keystrokes system-wide via a CGEventTap and maintains a rolling context of your recently typed words. As you type, it generates predictions through a multi-layer pipeline:

**Layer 1 — Instant predictions (< 10ms)**
- Prefix completions from Apple's built-in dictionary via `NSSpellChecker`
- Contextual re-ranking using a bigram/trigram model that learns your word patterns
- Semantic scoring via `NLEmbedding` for meaning-aware suggestions
- Personal dictionary injection for domain-specific terms (e.g., "kubernetes", "terraform")

**Layer 2 — AI-enhanced predictions (macOS 26+, optional)**
- On-device Foundation Models for deeper contextual understanding
- Results arrive asynchronously and refine Layer 1 suggestions in-place

The prediction model adapts over time. Early on, suggestions lean on dictionary rank. As TypeBoost learns your writing style through bigrams and trigrams with temporal decay, it shifts weight toward your personal patterns.

### Three Prediction Modes

- **Prefix completion** — Suggests words as you type each character
- **Next-word prediction** — After pressing space, suggests the most likely next word based on context
- **Spell correction** — Click on or arrow-navigate to a misspelled word to see corrections (highlighted with an orange border)

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `1` `2` `3` | Quick-select suggestion 1, 2, or 3 |
| `↑` | Activate suggestion selection mode |
| `← →` | Navigate between suggestions |
| `Enter` | Accept the highlighted suggestion |
| `Esc` | Dismiss suggestions for the current word |

## Features

- **System-wide** — Works in any app that accepts keyboard input
- **Privacy-first** — All data stays on your device, encrypted with AES-256-GCM
- **Learns your vocabulary** — Automatically picks up words you type frequently
- **Adaptive ranking** — Suggestions improve as the model observes your writing patterns
- **Non-intrusive** — Menu-bar only, no Dock icon, no main window
- **Smart exclusions** — Automatically pauses in password fields and Terminal apps
- **Per-app control** — Disable TypeBoost for specific applications via the menu bar

## Building from Source

### Prerequisites

- Xcode 15.0+
- macOS 13.0+ SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional, for regenerating the Xcode project)

### Steps

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/TypeBoost.git
cd TypeBoost

# If you need to regenerate the Xcode project from project.yml
brew install xcodegen
xcodegen generate

# Open in Xcode
open TypeBoost.xcodeproj

# Build and run (⌘R)
# Or build from the command line:
xcodebuild -project TypeBoost.xcodeproj -scheme TypeBoost -configuration Release build
```

After building, grant Accessibility and Input Monitoring permissions when prompted.

## Project Structure

```
TypeBoost/
├── App/                  # AppDelegate, main entry point
├── Core/                 # KeyboardMonitor, ContextManager, TextInserter, PermissionManager
├── Prediction/           # PredictionEngine, BigramModel, SemanticScorer, UserDictionary,
│                         # SpellCheckerEngine, FoundationModelEngine
├── UI/                   # SuggestionBarWindow, SuggestionBarView, SettingsView, MenuBarController
├── Models/               # AppSettings
├── Services/             # StorageService (encryption), AppIgnoreList, SecureInputDetector
└── Resources/            # Asset catalog
```

## How Data Is Stored

All user data lives in `~/Library/Application Support/TypeBoost/`:

| File | Contents |
|------|----------|
| `bigram_model.json` | Learned word-pair frequencies with timestamps |
| `user_dictionary.json` | Personal vocabulary (encrypted) |
| `settings.plist` | Preferences (enable/disable, ignored apps) |

The user dictionary is encrypted at rest using AES-256-GCM with a device-specific key. Bigram data is stored as plain JSON. No data is transmitted over the network.

## License

MIT

---

<p align="center">Built with Swift, AppKit, and NaturalLanguage.framework.</p>
