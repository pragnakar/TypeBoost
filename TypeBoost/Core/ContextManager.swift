// ContextManager.swift
// TypeBoost
//
// Maintains a rolling buffer of recently typed words and the word
// currently being composed. This context is fed to the prediction
// engine to produce ranked suggestions.

import Foundation
import ApplicationServices

// MARK: – TypingContext

/// Snapshot of the user's current typing state, consumed by PredictionEngine.
struct TypingContext {
    /// The partially typed word (e.g. "mee").
    let currentWord: String
    /// The most recent completed words (newest last), up to `maxHistory`.
    let previousWords: [String]
}

// MARK: – ContextManager

final class ContextManager {

    /// Maximum number of previous words to keep for bigram/trigram context.
    private let maxHistory = 20

    /// Characters of the word currently being typed.
    private(set) var currentWord: String = ""

    /// Completed words, newest last.
    private var previousWords: [String] = []

    /// When true, suggestions are suppressed for the current word
    /// (user pressed Escape). Resets on word boundary.
    private(set) var isCancelled: Bool = false

    // MARK: – Public API

    /// A snapshot of the current typing context for the prediction engine.
    var typingContext: TypingContext {
        TypingContext(
            currentWord: currentWord,
            previousWords: Array(previousWords.suffix(maxHistory))
        )
    }

    /// Append a character to the word being composed.
    func appendCharacter(_ char: Character) {
        // If the user deleted all characters and starts over, re-enable suggestions.
        if currentWord.isEmpty {
            isCancelled = false
        }
        currentWord.append(char)
    }

    /// Remove the last character (backspace).
    ///
    /// When `currentWord` is empty, the user is backspacing past a word
    /// boundary — deleting the space/punctuation that follows the previous
    /// word. We "reopen" that word by popping it from `previousWords` back
    /// into `currentWord`. The on-screen deletion handles itself (the
    /// backspace event passes through to the target app); we just need to
    /// keep the shadow state in sync.
    ///
    /// Example: user accepted "hippopotamus " via suggestion →
    ///   currentWord = "", previousWords = [..., "hippopotamus"]
    /// First backspace deletes the trailing space:
    ///   currentWord = "hippopotamus" (reopened), previousWords shrinks by 1
    /// Second backspace deletes "s":
    ///   currentWord = "hippopotamu"
    func deleteLastCharacter() {
        if currentWord.isEmpty {
            // Backspacing past a word boundary — reopen the previous word.
            // The on-screen backspace deletes the space/punctuation separator;
            // the word itself is now editable again.
            if let lastWord = previousWords.popLast() {
                currentWord = lastWord
                isCancelled = false
            }
            return
        }
        currentWord.removeLast()
        // If the entire word is deleted, treat the next input as a new word.
        if currentWord.isEmpty {
            isCancelled = false
        }
    }

    /// The user completed the current word (space / punctuation).
    func commitCurrentWord() {
        let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            previousWords.append(trimmed.lowercased())
            if previousWords.count > maxHistory {
                previousWords.removeFirst(previousWords.count - maxHistory)
            }
        }
        currentWord = ""
        isCancelled = false
    }

    /// The user accepted a suggestion; treat it as a committed word.
    func acceptSuggestion(_ word: String) {
        previousWords.append(word.lowercased())
        if previousWords.count > maxHistory {
            previousWords.removeFirst(previousWords.count - maxHistory)
        }
        currentWord = ""
        isCancelled = false
    }

    /// The user pressed Escape — suppress suggestions for this word.
    func cancelCurrentWord() {
        isCancelled = true
    }

    /// Full reset (e.g. when the user switches apps).
    func reset() {
        currentWord = ""
        previousWords.removeAll()
        isCancelled = false
    }

    // MARK: – Word Under Cursor (for spell-check mode)

    /// Reads the complete word at the current cursor position using AX.
    /// Used for spell-check mode when the user clicks on or navigates to a word.
    func wordUnderCursor() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedObj = focusedRef else { return nil }
        // AXUIElement is a CF type — the downcast always succeeds if non-nil.
        let focused = focusedObj as! AXUIElement

        // Get full text value of the element.
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef
        ) == .success, let fullText = valueRef as? String else { return nil }

        // Get cursor position.
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeObj = rangeRef else { return nil }

        var cfRange = CFRange(location: 0, length: 0)
        AXValueGetValue(rangeObj as! AXValue, .cfRange, &cfRange)

        let cursorIndex = cfRange.location
        let str = fullText as NSString
        guard cursorIndex <= str.length else { return nil }

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

        guard end > start else { return nil }
        let word = str.substring(with: NSRange(location: start, length: end - start))
        return word.isEmpty ? nil : word
    }
}
