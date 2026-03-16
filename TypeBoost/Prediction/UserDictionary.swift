// UserDictionary.swift
// TypeBoost
//
// Learns from the user's typing patterns over time. Tracks:
//   • Words typed manually (not from suggestions) — added to the custom
//     dictionary after a configurable threshold (default 3 occurrences).
//   • Suggestion acceptances — boosts the accepted word's score.
//   • Suggestion ignores — decreases the score for repeatedly-ignored words.
//
// All data is stored locally in an encrypted JSON file within the app's
// Application Support directory.

import Foundation

// MARK: – LearnedWord

struct LearnedWord: Codable {
    var word: String
    var manualCount: Int     // Times typed without suggestion
    var acceptCount: Int     // Times accepted from suggestions
    var ignoreCount: Int     // Times the word was suggested but ignored
    var lastUsed: Date
}

// MARK: – UserDictionary

final class UserDictionary {

    /// Threshold: a manually-typed word is added to the user dictionary
    /// after this many occurrences.
    static let learningThreshold = 3

    /// Words learned from the user, keyed by lowercased word.
    private(set) var words: [String: LearnedWord] = [:] {
        didSet { _learnedWordsCache = nil }
    }

    /// Cached list of learned words, invalidated on any mutation to `words`.
    private var _learnedWordsCache: [String]?

    /// Whether learning is enabled (user can toggle this off).
    var isLearningEnabled: Bool = true

    private let storageURL: URL

    // MARK: – Init

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let appSupport = base.appendingPathComponent("TypeBoost", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        storageURL = appSupport.appendingPathComponent("user_dictionary.json")
        load()
    }

    // MARK: – Learning

    /// Record that the user typed a word manually (without accepting a suggestion).
    func recordManualEntry(_ word: String) {
        guard isLearningEnabled else { return }
        let key = word.lowercased()
        var entry = words[key] ?? LearnedWord(
            word: key, manualCount: 0, acceptCount: 0, ignoreCount: 0, lastUsed: Date()
        )
        entry.manualCount += 1
        entry.lastUsed = Date()
        words[key] = entry
        saveDebounced()
    }

    /// Record that the user accepted a suggestion.
    func recordAcceptance(_ word: String) {
        guard isLearningEnabled else { return }
        let key = word.lowercased()
        var entry = words[key] ?? LearnedWord(
            word: key, manualCount: 0, acceptCount: 0, ignoreCount: 0, lastUsed: Date()
        )
        entry.acceptCount += 1
        entry.lastUsed = Date()
        words[key] = entry
        saveDebounced()
    }

    // MARK: – Scoring

    /// Returns a user-preference bonus for the given word, in the range [0, 1].
    func bonus(for word: String) -> Double {
        guard let entry = words[word.lowercased()] else { return 0 }
        let total = entry.acceptCount + entry.manualCount
        guard total > 0 else { return 0 }

        // Logarithmic scaling to avoid runaway scores.
        return min(1.0, log2(Double(total + 1)) / 10.0)
    }

    /// Whether the word qualifies as a "learned" user word (meets threshold).
    func isLearnedWord(_ word: String) -> Bool {
        guard let entry = words[word.lowercased()] else { return false }
        return entry.manualCount >= Self.learningThreshold || entry.acceptCount >= 1
    }

    /// All words that meet the learning threshold, suitable for boosting
    /// in the prediction engine. Cached to avoid O(n) recomputation per keystroke.
    var learnedWords: [String] {
        if let cached = _learnedWordsCache { return cached }
        let result = words.values
            .filter { $0.manualCount >= Self.learningThreshold || $0.acceptCount >= 1 }
            .map(\.word)
        _learnedWordsCache = result
        return result
    }

    // MARK: – Data Management

    func resetAll() {
        words.removeAll()
        save()
    }

    // MARK: – Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let raw = try Data(contentsOf: storageURL)
            // Try decrypting first (new format).
            let data: Data
            if let decrypted = try? StorageService.decrypt(raw) {
                data = decrypted
            } else {
                // Fall back to plain JSON (migration from unencrypted format).
                data = raw
            }
            let decoded = try JSONDecoder().decode([String: LearnedWord].self, from: data)
            words = decoded
        } catch {
            #if DEBUG
            NSLog("[TypeBoost] Failed to load user dictionary: \(error)")
            #endif
        }
    }

    func save() {
        do {
            let json = try JSONEncoder().encode(words)
            let encrypted = try StorageService.encrypt(json)
            try encrypted.write(to: storageURL, options: .atomic)
        } catch {
            #if DEBUG
            NSLog("[TypeBoost] Failed to save user dictionary: \(error)")
            #endif
        }
    }

    private var pendingSave: DispatchWorkItem?
    private func saveDebounced() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: item)
    }
}
