// BigramModel.swift
// TypeBoost
//
// A lightweight bigram / trigram model that scores word predictions based on
// the words that immediately precede them. The model is populated with
// common English word transitions at launch and refined as the user types.
//
// Scoring: given previous word(s), the model returns a bonus score for each
// candidate completion, which the PredictionEngine blends with frequency
// and recency scores. Temporal decay (exp(-0.03 * days)) ensures recent
// observations outweigh stale ones.

import Foundation

// MARK: – BigramEntry

/// A single bigram/trigram observation with a timestamp for temporal decay.
struct BigramEntry: Codable {
    var count: Int
    var lastSeen: Date
}

final class BigramModel {

    // MARK: – Storage

    /// bigrams[prevWord][nextWord] = observation entry.
    private var bigrams: [String: [String: BigramEntry]] = [:]

    /// trigrams["w1 w2"][nextWord] = observation entry.
    private var trigrams: [String: [String: BigramEntry]] = [:]

    /// Total transition count per context (for normalisation).
    private var bigramTotals: [String: Int] = [:]
    private var trigramTotals: [String: Int] = [:]

    /// Maximum number of context keys before eviction kicks in.
    private let maxContextKeys = 5000

    /// Decay constant: 0.03 ≈ half-life of ~23 days.
    /// 1 day: 97%, 7 days: 81%, 30 days: 41%, 90 days: 7%.
    private let decayLambda = 0.03

    /// Number of unique bigram pairs learned from user typing (not seeds).
    /// Used by PredictionEngine to determine model maturity.
    private(set) var userObservationCount: Int = 0

    /// Observations since last save. Used to trigger periodic persistence.
    private var observationsSinceLastSave: Int = 0

    /// Observations since the last eviction sort (separate counters per model).
    /// Eviction is O(n log n) on 5000 keys — only worth running every N adds.
    private var bigramObservationsSinceEviction: Int = 0
    private var trigramObservationsSinceEviction: Int = 0
    private let evictionCheckInterval = 500

    /// Called when the model should be persisted (every 100 observations).
    var onNeedsSave: (() -> Void)?

    // MARK: – Recording

    /// Record that `next` followed `prev` in the user's typing.
    func recordBigram(prev: String, next: String) {
        let p = prev.lowercased()
        let n = next.lowercased()
        let isNew = bigrams[p]?[n] == nil
        var entry = bigrams[p, default: [:]][n] ?? BigramEntry(count: 0, lastSeen: Date())
        entry.count += 1
        entry.lastSeen = Date()
        bigrams[p, default: [:]][n] = entry
        bigramTotals[p, default: 0] += 1
        if isNew { userObservationCount += 1 }
        observationsSinceLastSave += 1
        if observationsSinceLastSave >= 100 {
            observationsSinceLastSave = 0
            onNeedsSave?()
        }
        evictBigramsIfNeeded()
    }

    /// Record a trigram (w1, w2) → next.
    func recordTrigram(w1: String, w2: String, next: String) {
        let key = "\(w1.lowercased()) \(w2.lowercased())"
        let n = next.lowercased()
        var entry = trigrams[key, default: [:]][n] ?? BigramEntry(count: 0, lastSeen: Date())
        entry.count += 1
        entry.lastSeen = Date()
        trigrams[key, default: [:]][n] = entry
        trigramTotals[key, default: 0] += 1
        evictTrigramsIfNeeded()
    }

    // MARK: – Scoring

    /// Returns a context bonus in the range [0, 1] for the candidate word
    /// given the previous word(s). Applies exponential temporal decay.
    func score(candidate: String, previousWords: [String]) -> Double {
        let c = candidate.lowercased()
        var bigramScore = 0.0
        var trigramScore = 0.0
        let now = Date()

        // Bigram score: P(candidate | last word) with decay
        if let lastWord = previousWords.last {
            let p = lastWord.lowercased()
            if let nextMap = bigrams[p], let entry = nextMap[c],
               let total = bigramTotals[p], total > 0 {
                let daysSince = max(0, now.timeIntervalSince(entry.lastSeen) / 86400)
                let decayed = Double(entry.count) * exp(-decayLambda * daysSince)
                bigramScore = decayed / Double(total)
            }
        }

        // Trigram score: P(candidate | second-to-last, last) with decay
        if previousWords.count >= 2 {
            let w1 = previousWords[previousWords.count - 2].lowercased()
            let w2 = previousWords[previousWords.count - 1].lowercased()
            let key = "\(w1) \(w2)"
            if let nextMap = trigrams[key], let entry = nextMap[c],
               let total = trigramTotals[key], total > 0 {
                let daysSince = max(0, now.timeIntervalSince(entry.lastSeen) / 86400)
                let decayed = Double(entry.count) * exp(-decayLambda * daysSince)
                trigramScore = decayed / Double(total)
            }
        }

        // Blend: trigram evidence is stronger when available.
        if trigramScore > 0 {
            return 0.4 * bigramScore + 0.6 * trigramScore
        }
        return bigramScore
    }

    // MARK: – Reset

    /// Clears all learned bigram/trigram data and re-seeds with defaults.
    /// Called by PredictionEngine.resetAllLearning() when the user resets learned data.
    func reset() {
        bigrams.removeAll()
        trigrams.removeAll()
        bigramTotals.removeAll()
        trigramTotals.removeAll()
        userObservationCount = 0
        observationsSinceLastSave = 0
        bigramObservationsSinceEviction = 0
        trigramObservationsSinceEviction = 0
        seedDefaults()
    }

    // MARK: – Seeding

    /// Seed the model with common English word pairs.
    /// Uses epoch date so seeds decay heavily as user data accumulates.
    func seedDefaults() {
        let seedDate = Date(timeIntervalSince1970: 0)

        let commonPairs: [(String, String, Int)] = [
            ("i", "am", 500), ("i", "will", 400), ("i", "have", 380),
            ("i", "was", 350), ("i", "think", 320), ("i", "can", 310),
            ("i", "would", 300), ("i", "need", 280), ("i", "want", 270),
            ("i", "don't", 260),
            ("the", "best", 300), ("the", "first", 280), ("the", "same", 260),
            ("the", "most", 250), ("the", "other", 240), ("the", "new", 230),
            ("the", "world", 200), ("the", "time", 190), ("the", "way", 180),
            ("to", "be", 400), ("to", "do", 350), ("to", "get", 320),
            ("to", "make", 300), ("to", "have", 280), ("to", "go", 260),
            ("to", "see", 240), ("to", "know", 230), ("to", "take", 220),
            ("it", "is", 500), ("it", "was", 450), ("it", "will", 300),
            ("it", "would", 250), ("it", "can", 200),
            ("in", "the", 500), ("in", "a", 350), ("in", "this", 250),
            ("of", "the", 600), ("of", "a", 300), ("of", "this", 200),
            ("that", "is", 400), ("that", "was", 350), ("that", "the", 300),
            ("for", "the", 400), ("for", "a", 300), ("for", "this", 200),
            ("on", "the", 400), ("on", "a", 250),
            ("with", "the", 350), ("with", "a", 300),
            ("is", "a", 400), ("is", "the", 350), ("is", "not", 300),
            ("was", "a", 350), ("was", "the", 300), ("was", "not", 250),
            ("will", "be", 500), ("will", "have", 300), ("will", "not", 250),
            ("have", "been", 400), ("have", "to", 350), ("have", "a", 300),
            ("are", "not", 300), ("are", "the", 250), ("are", "you", 200),
            ("do", "not", 400), ("do", "you", 350),
            ("would", "be", 400), ("would", "have", 300), ("would", "like", 250),
            ("could", "be", 350), ("could", "have", 300), ("could", "not", 250),
            ("should", "be", 350), ("should", "have", 300), ("should", "not", 250),
            ("can", "be", 350), ("can", "you", 200),
            ("this", "is", 400), ("this", "was", 300),
            ("there", "is", 350), ("there", "are", 300), ("there", "was", 250),
            ("we", "are", 350), ("we", "have", 300), ("we", "will", 280),
            ("we", "can", 250), ("we", "need", 230),
            ("they", "are", 350), ("they", "have", 300), ("they", "will", 250),
            ("you", "are", 400), ("you", "can", 350), ("you", "have", 300),
            ("you", "will", 280), ("you", "need", 250),
            ("how", "to", 400), ("how", "do", 300), ("how", "is", 200),
            ("what", "is", 400), ("what", "are", 300), ("what", "do", 250),
            ("when", "the", 300), ("when", "you", 250),
            ("if", "you", 350), ("if", "the", 300), ("if", "it", 250),
            ("at", "the", 400), ("at", "a", 250),
            ("by", "the", 350), ("as", "a", 300), ("as", "the", 250),
            ("from", "the", 350), ("from", "a", 250),
            ("but", "the", 250), ("but", "it", 200), ("but", "i", 200),
            ("not", "be", 300), ("not", "have", 250), ("not", "the", 200),
            ("all", "the", 300), ("all", "of", 250),
            ("been", "a", 250), ("been", "the", 200),
            ("has", "been", 350), ("has", "a", 250), ("has", "the", 200),
            ("had", "been", 300), ("had", "a", 250), ("had", "the", 200),
        ]

        for (prev, next, count) in commonPairs {
            bigrams[prev, default: [:]][next] = BigramEntry(count: count, lastSeen: seedDate)
            bigramTotals[prev, default: 0] += count
        }
    }

    // MARK: – Next-Word Lookup

    /// Returns the most likely words to follow `word`, sorted by decayed score.
    func topNextWords(after word: String, limit: Int) -> [String] {
        let key = word.lowercased()
        guard let nexts = bigrams[key] else { return [] }
        let now = Date()
        return nexts
            .map { (word: $0.key, decayed: Double($0.value.count) * exp(-decayLambda * max(0, now.timeIntervalSince($0.value.lastSeen) / 86400))) }
            .sorted { $0.decayed > $1.decayed }
            .prefix(limit)
            .map { $0.word }
    }

    /// Returns the most likely words to follow the word pair (w1, w2), sorted by decayed score.
    func topNextWords(afterPair w1: String, and w2: String, limit: Int) -> [String] {
        let key = "\(w1.lowercased()) \(w2.lowercased())"
        guard let nexts = trigrams[key] else { return [] }
        let now = Date()
        return nexts
            .map { (word: $0.key, decayed: Double($0.value.count) * exp(-decayLambda * max(0, now.timeIntervalSince($0.value.lastSeen) / 86400))) }
            .sorted { $0.decayed > $1.decayed }
            .prefix(limit)
            .map { $0.word }
    }

    // MARK: – Eviction

    /// Removes the stalest bigram context keys when the cap is exceeded.
    /// Prefers evicting keys with the oldest lastSeen dates.
    private func evictBigramsIfNeeded() {
        bigramObservationsSinceEviction += 1
        guard bigramObservationsSinceEviction >= evictionCheckInterval else { return }
        bigramObservationsSinceEviction = 0
        guard bigrams.count > maxContextKeys else { return }
        // Find the oldest lastSeen per context key.
        let keysWithAge: [(key: String, oldestSeen: Date)] = bigrams.map { key, nexts in
            let oldest = nexts.values.map(\.lastSeen).min() ?? .distantPast
            return (key, oldest)
        }
        let sorted = keysWithAge.sorted { $0.oldestSeen < $1.oldestSeen }
        let toRemove = sorted.prefix(bigrams.count - maxContextKeys)
        for item in toRemove {
            bigrams.removeValue(forKey: item.key)
            bigramTotals.removeValue(forKey: item.key)
        }
    }

    /// Removes the stalest trigram context keys when the cap is exceeded.
    private func evictTrigramsIfNeeded() {
        trigramObservationsSinceEviction += 1
        guard trigramObservationsSinceEviction >= evictionCheckInterval else { return }
        trigramObservationsSinceEviction = 0
        guard trigrams.count > maxContextKeys else { return }
        let keysWithAge: [(key: String, oldestSeen: Date)] = trigrams.map { key, nexts in
            let oldest = nexts.values.map(\.lastSeen).min() ?? .distantPast
            return (key, oldest)
        }
        let sorted = keysWithAge.sorted { $0.oldestSeen < $1.oldestSeen }
        let toRemove = sorted.prefix(trigrams.count - maxContextKeys)
        for item in toRemove {
            trigrams.removeValue(forKey: item.key)
            trigramTotals.removeValue(forKey: item.key)
        }
    }

    // MARK: – Persistence (JSON)

    /// V2 format: BigramEntry with timestamps and observation count.
    private struct SerializedModelV2: Codable {
        var bigrams: [String: [String: BigramEntry]]
        var trigrams: [String: [String: BigramEntry]]
        var userObservationCount: Int
    }

    /// V1 format: plain Int counts (for backwards compatibility).
    private struct SerializedModelV1: Codable {
        var bigrams: [String: [String: Int]]
        var trigrams: [String: [String: Int]]
    }

    func serialise() -> Data {
        let model = SerializedModelV2(
            bigrams: bigrams,
            trigrams: trigrams,
            userObservationCount: userObservationCount
        )
        return (try? JSONEncoder().encode(model)) ?? Data()
    }

    func deserialise(from data: Data) {
        // Try V2 format first (BigramEntry with timestamps).
        if let model = try? JSONDecoder().decode(SerializedModelV2.self, from: data) {
            // Replace (not merge) — the persisted file is the complete model state.
            bigrams = model.bigrams
            trigrams = model.trigrams
            userObservationCount = model.userObservationCount

            // Rebuild totals from the loaded data.
            bigramTotals.removeAll()
            for (prev, nexts) in bigrams {
                bigramTotals[prev] = nexts.values.reduce(0) { $0 + $1.count }
            }
            trigramTotals.removeAll()
            for (key, nexts) in trigrams {
                trigramTotals[key] = nexts.values.reduce(0) { $0 + $1.count }
            }
            return
        }

        // Fall back to V1 format (plain Int counts) — migrate to BigramEntry.
        if let model = try? JSONDecoder().decode(SerializedModelV1.self, from: data) {
            let now = Date()
            for (prev, nexts) in model.bigrams {
                for (next, count) in nexts {
                    let entry = BigramEntry(count: count, lastSeen: now)
                    bigrams[prev, default: [:]][next] = entry
                    bigramTotals[prev, default: 0] += count
                }
            }
            for (key, nexts) in model.trigrams {
                for (next, count) in nexts {
                    let entry = BigramEntry(count: count, lastSeen: now)
                    trigrams[key, default: [:]][next] = entry
                    trigramTotals[key, default: 0] += count
                }
            }
            return
        }

        // Fall back to legacy tab-separated format.
        deserialiseLegacy(from: data)
    }

    /// Reads the old tab-separated format for backwards compatibility.
    private func deserialiseLegacy(from data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let now = Date()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count == 4, parts[0] == "B", let count = Int(parts[3]) {
                let prev = String(parts[1])
                let next = String(parts[2])
                bigrams[prev, default: [:]][next] = BigramEntry(count: count, lastSeen: now)
                bigramTotals[prev, default: 0] += count
            } else if parts.count == 4, parts[0] == "T", let count = Int(parts[3]) {
                let key = String(parts[1])
                let next = String(parts[2])
                trigrams[key, default: [:]][next] = BigramEntry(count: count, lastSeen: now)
                trigramTotals[key, default: 0] += count
            }
        }
    }
}
