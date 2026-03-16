// PredictionEngine.swift
// TypeBoost
//
// The central prediction coordinator. Combines:
//   Layer 1 — SpellCheckerEngine (NSSpellChecker prefix completions)
//   Layer 1b — BigramModel (contextual re-ranking)
//   Layer 1c — UserDictionary (personalisation boost)
//   Layer 2 — FoundationModelEngine (async contextual AI, when available)
//
// The engine always returns results from Layer 1 synchronously. Layer 2
// results, when available, asynchronously refine the suggestions.

import Foundation

// MARK: – Suggestion

struct Suggestion: Equatable, Identifiable {
    let id = UUID()
    let word: String
    /// Combined score used for ranking (higher = better).
    let score: Double
}

// MARK: – PredictionEngine

final class PredictionEngine {

    // MARK: – Components

    let spellChecker = SpellCheckerEngine()
    private let bigramModel = BigramModel()
    private let userDictionary: UserDictionary
    private let contextualProvider: ContextualPredictionProvider
    private let semanticScorer = SemanticScorer()

    /// Maximum number of suggestions returned.
    private let maxSuggestions = 3

    /// Cache for the most recent Layer 2 results.
    private var layer2Cache: [String]?
    private var layer2CachePrefix: String?
    private var layer2Task: Task<Void, Never>?

    // MARK: – Init

    /// Timer for periodic bigram saves.
    private var periodicSaveTimer: Timer?

    init(userDictionary: UserDictionary) {
        self.userDictionary = userDictionary
        self.contextualProvider = ContextualProviderFactory.makeProvider()

        // Save after every 100 new bigram observations.
        bigramModel.onNeedsSave = { [weak self] in
            self?.saveBigramModel()
        }

        // Also save every 5 minutes as a safety net.
        periodicSaveTimer = Timer.scheduledTimer(
            withTimeInterval: 300, repeats: true
        ) { [weak self] _ in
            self?.saveBigramModel()
        }

        #if DEBUG
        NSLog("[TypeBoost] PredictionEngine ready — using NSSpellChecker.")
        #endif
    }

    // MARK: – Prediction (synchronous, Layer 1)

    /// Generates up to 3 suggestions for the current typing context.
    /// This is the primary call from the main thread and must return fast (<10 ms).
    func predict(context: TypingContext) -> [Suggestion] {
        let prefix = context.currentWord.lowercased()
        guard !prefix.isEmpty else { return [] }

        // 1. Get completions from NSSpellChecker (top 20 for re-ranking).
        let spellCheckerCandidates = spellChecker.completions(for: prefix, limit: 20)

        // 1b. Inject learned words that match the prefix but aren't already
        //     in the NSSpellChecker pool. This surfaces domain-specific words
        //     (e.g. "kubernetes", "terraform") that Apple's dictionary omits.
        let candidateSet = Set(spellCheckerCandidates.map { $0.lowercased() })
        let injected = userDictionary.learnedWords
            .filter { $0.hasPrefix(prefix) && $0.count > prefix.count && !candidateSet.contains($0) }
            .prefix(5)
        let allCandidates = spellCheckerCandidates + injected

        guard !allCandidates.isEmpty else { return [] }

        // 2. Adaptive weights: lean on rank early, shift toward context as
        //    bigrams accumulate from actual user typing.
        let maturity = min(1.0, Double(bigramModel.userObservationCount) / 5000.0)
        let rankWeight     = 0.60 - 0.20 * maturity   // 0.60 → 0.40
        let contextWeight  = 0.10 + 0.25 * maturity   // 0.10 → 0.35
        let semanticWeight = 0.15                      // constant
        let userWeight     = 0.15                      // constant

        let hasSemantic = semanticScorer.isAvailable && !context.previousWords.isEmpty

        // 3. Score each candidate.
        let candidateCount = Double(allCandidates.count + 1)
        var scored: [(word: String, score: Double)] = allCandidates.enumerated().map { index, word in
            let w = word.lowercased()
            let rankScore = 1.0 - (Double(index) / candidateCount)
            let contextScore = bigramModel.score(
                candidate: w,
                previousWords: context.previousWords
            )
            let userBonus = userDictionary.bonus(for: w)
            let semanticScore = hasSemantic
                ? semanticScorer.score(candidate: w, contextWords: context.previousWords)
                : 0

            let total = rankWeight * rankScore
                      + contextWeight * contextScore
                      + semanticWeight * semanticScore
                      + userWeight * userBonus
            return (w, total)
        }

        // 4. Incorporate Layer 2 cache if the prefix matches.
        if let cached = layer2Cache, layer2CachePrefix == prefix {
            for (i, aiWord) in cached.enumerated() {
                let aiBonus = 0.3 * (1.0 - Double(i) * 0.1)
                if let idx = scored.firstIndex(where: { $0.word == aiWord }) {
                    scored[idx].score += aiBonus
                } else {
                    scored.append((aiWord, aiBonus))
                }
            }
        }

        // 5. Sort descending by score.
        scored.sort { $0.score > $1.score }

        // 6. Deduplicate.
        var seen = Set<String>()
        let unique = scored.filter { seen.insert($0.word).inserted }

        // 7. Take top N.
        let results = Array(unique.prefix(maxSuggestions)).map {
            Suggestion(word: $0.word, score: $0.score)
        }

        // 8. Fire off async Layer 2 request.
        requestLayer2(context: context)

        return results
    }

    // MARK: – Spell Check

    /// Returns true if the given word is misspelled.
    func isMisspelled(_ word: String) -> Bool {
        spellChecker.isMisspelled(word)
    }

    /// Returns correction suggestions for a misspelled word.
    func corrections(for word: String) -> [String] {
        spellChecker.corrections(for: word)
    }

    /// Teach the spell checker a new word.
    func learnWord(_ word: String) {
        spellChecker.learnWord(word)
    }

    // MARK: – Next-Word Prediction (synchronous)

    /// Predicts the most likely next word given the current context.
    /// Returns results instantly from the bigram model.
    /// Called synchronously from the main thread after a space is pressed.
    func predictNextWord(context: TypingContext) -> [Suggestion] {
        guard !context.previousWords.isEmpty else { return [] }

        let lastWord = context.previousWords.last ?? ""
        let secondLastWord = context.previousWords.dropLast().last ?? ""

        // 1. Get bigram candidates — words that commonly follow lastWord.
        let bigramCandidates = bigramModel.topNextWords(after: lastWord, limit: 10)

        // 2. Get trigram candidates — words that follow (secondLast, last).
        let trigramCandidates = bigramModel.topNextWords(
            afterPair: secondLastWord, and: lastWord, limit: 10
        )

        // 3. Merge and score all candidates.
        var scores: [String: Double] = [:]

        for (i, word) in trigramCandidates.enumerated() {
            scores[word, default: 0] += 1.0 - Double(i) * 0.08
        }
        for (i, word) in bigramCandidates.enumerated() {
            scores[word, default: 0] += 0.7 - Double(i) * 0.06
        }

        // 4. Apply user bonus.
        for word in scores.keys {
            scores[word]! += userDictionary.bonus(for: word) * 0.2
        }

        // 5. Apply semantic scoring bonus.
        if semanticScorer.isAvailable {
            for word in scores.keys {
                let semScore = semanticScorer.score(
                    candidate: word,
                    contextWords: context.previousWords
                )
                scores[word]! += semScore * 0.25
            }
        }

        // 6. Sort and return top 3.
        let results = scores
            .sorted { $0.value > $1.value }
            .prefix(maxSuggestions)
            .map { Suggestion(word: $0.key, score: $0.value) }

        return results
    }

    // MARK: – Next-Word Prediction (async)

    private var nextWordTask: Task<Void, Never>?

    /// Async next-word prediction using Foundation Models.
    /// Calls `completion` on the main thread when results are ready.
    func predictNextWordAsync(
        context: TypingContext,
        completion: @escaping ([Suggestion]) -> Void
    ) {
        guard contextualProvider.isAvailable else { return }

        nextWordTask?.cancel()
        nextWordTask = Task { [weak self] in
            guard let self else { return }
            let words = await Self.withTimeout(seconds: 4) {
                await self.contextualProvider.predictNextWord(context: context)
            } ?? []
            guard !Task.isCancelled, !words.isEmpty else { return }

            let suggestions = words.enumerated().map { i, word in
                Suggestion(word: word, score: 1.0 - Double(i) * 0.1)
            }
            await MainActor.run {
                completion(suggestions)
            }
        }
    }

    /// Cancel any pending next-word async task.
    func cancelNextWordPrediction() {
        nextWordTask?.cancel()
        nextWordTask = nil
    }

    // MARK: – Layer 2 (async)

    private func requestLayer2(context: TypingContext) {
        guard contextualProvider.isAvailable else { return }
        let prefix = context.currentWord.lowercased()

        if layer2CachePrefix == prefix { return }

        layer2Task?.cancel()
        layer2Task = Task { [weak self] in
            guard let self else { return }
            let results = await Self.withTimeout(seconds: 4) {
                await self.contextualProvider.predict(
                    context: context, limit: 3
                )
            } ?? []
            guard !Task.isCancelled, !results.isEmpty else { return }
            await MainActor.run {
                self.layer2Cache = results
                self.layer2CachePrefix = prefix
            }
        }
    }

    // MARK: – Timeout Helper

    /// Runs an async closure with a timeout. Returns nil if the timeout expires.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: – Learning Feedback

    /// Called when the user accepts a suggestion.
    func recordAcceptance(_ suggestion: Suggestion) {
        spellChecker.learnWord(suggestion.word)
        userDictionary.recordAcceptance(suggestion.word)
    }

    /// Called when the user completes a word without accepting a suggestion.
    func recordManualEntry(_ word: String) {
        userDictionary.recordManualEntry(word)
    }

    /// Record bigram transitions for context learning.
    func recordWordTransition(previous: String, current: String) {
        bigramModel.recordBigram(prev: previous, next: current)
    }

    /// Record trigram transitions for context learning.
    func recordTrigramTransition(w1: String, w2: String, next: String) {
        bigramModel.recordTrigram(w1: w1, w2: w2, next: next)
    }

    // MARK: – BigramModel Persistence

    private static let bigramFileName = "bigram_model.json"

    /// Load persisted bigram/trigram data from disk. Call at launch.
    func loadBigramModel() {
        guard StorageService.exists(Self.bigramFileName) else {
            // No persisted data — seed with common English word pairs.
            bigramModel.seedDefaults()
            return
        }
        do {
            let data = try StorageService.read(Self.bigramFileName)
            bigramModel.deserialise(from: data)
            #if DEBUG
            NSLog("[TypeBoost] BigramModel loaded from disk.")
            #endif
        } catch {
            #if DEBUG
            NSLog("[TypeBoost] Failed to load BigramModel: \(error)")
            #endif
            // Load failed — seed defaults as fallback.
            bigramModel.seedDefaults()
        }
    }

    /// Persist the bigram/trigram model to disk. Call at shutdown.
    func saveBigramModel() {
        let data = bigramModel.serialise()
        guard !data.isEmpty else { return }
        do {
            try StorageService.write(data, to: Self.bigramFileName)
            #if DEBUG
            NSLog("[TypeBoost] BigramModel saved to disk.")
            #endif
        } catch {
            #if DEBUG
            NSLog("[TypeBoost] Failed to save BigramModel: \(error)")
            #endif
        }
    }
}
