// SpellCheckerEngine.swift
// TypeBoost
//
// Wraps NSSpellChecker to provide fast prefix-based word completions
// and spell correction. Replaces the hand-built trie. Uses Apple's full
// system dictionary, all user-enabled languages, and the user's learned
// vocabulary automatically.

import AppKit

final class SpellCheckerEngine {

    private let checker = NSSpellChecker.shared
    private let documentTag = NSSpellChecker.uniqueSpellDocumentTag()

    // MARK: – Completions

    /// Returns up to `limit` word completions for the given prefix.
    func completions(for prefix: String, limit: Int) -> [String] {
        guard !prefix.isEmpty else { return [] }

        let range = NSRange(location: 0, length: prefix.utf16.count)

        let results = checker.completions(
            forPartialWordRange: range,
            in: prefix,
            language: nil,
            inSpellDocumentWithTag: documentTag
        ) ?? []

        // Must start with the prefix and be longer (actual completion, not echo).
        let lowerPrefix = prefix.lowercased()
        let filtered = results.filter {
            $0.lowercased().hasPrefix(lowerPrefix) && $0.count > prefix.count
        }

        return Array(filtered.prefix(limit))
    }

    // MARK: – Spell Check

    /// Returns true if the given word is misspelled.
    func isMisspelled(_ word: String) -> Bool {
        guard word.count > 1 else { return false }
        let range = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: nil,
            wrap: false,
            inSpellDocumentWithTag: documentTag,
            wordCount: nil
        )
        return range.location != NSNotFound
    }

    /// Returns correction suggestions for a misspelled word.
    func corrections(for word: String) -> [String] {
        guard !word.isEmpty else { return [] }

        let range = NSRange(location: 0, length: word.utf16.count)

        let guesses = checker.guesses(
            forWordRange: range,
            in: word,
            language: nil,
            inSpellDocumentWithTag: documentTag
        ) ?? []

        var allSuggestions = guesses

        if let best = checker.correction(
            forWordRange: range,
            in: word,
            language: checker.language(),
            inSpellDocumentWithTag: documentTag
        ), !allSuggestions.contains(best) {
            allSuggestions.insert(best, at: 0)
        }

        return Array(allSuggestions.prefix(3))
    }

    // MARK: – Next-Word (stub)

    /// Hook for future next-word prediction via NSSpellChecker.
    /// NSSpellChecker's public API does not expose next-word prediction
    /// directly — only prefix completion. The bigram model and Foundation
    /// Models are the real engines for next-word. This stub exists as a
    /// hook for a future CoreML integration.
    func nextWordSuggestions(after previousWord: String, limit: Int) -> [String] {
        return []
    }

    // MARK: – Learning

    /// Tell the spell checker this word was accepted by the user.
    func learnWord(_ word: String) {
        if !checker.hasLearnedWord(word) {
            checker.learnWord(word)
        }
    }

    /// Forget a previously learned word.
    func unlearnWord(_ word: String) {
        if checker.hasLearnedWord(word) {
            checker.unlearnWord(word)
        }
    }
}
