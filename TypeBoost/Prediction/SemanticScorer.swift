// SemanticScorer.swift
// TypeBoost
//
// Uses Apple's NLEmbedding (NaturalLanguage framework) to compute
// semantic similarity between recent context words and completion
// candidates. This provides a generalisation signal that the bigram
// model cannot — it scores candidates the user has never literally
// typed after the current context word.

import Foundation
import NaturalLanguage

final class SemanticScorer {

    private let embedding: NLEmbedding?

    init() {
        embedding = NLEmbedding.wordEmbedding(for: .english)
    }

    /// Whether semantic scoring is available (embedding loaded).
    var isAvailable: Bool { embedding != nil }

    /// Returns a semantic relevance score in [0, 1] for the candidate
    /// given the recent context words.
    ///
    /// Strategy: recency-weighted average of per-word cosine similarity scores
    /// across the last 5 context words. More recent words carry more weight so
    /// the current topical context dominates over older, unrelated words.
    /// 5-word window (up from 3) gives richer topical signal now that Foundation
    /// Models are disabled and NLEmbedding is the primary generalisation layer.
    ///
    ///   weights (oldest → newest): [0.05, 0.10, 0.15, 0.25, 0.45]
    ///
    /// NLEmbedding cosine distance is in [0, 2]; converted to score via
    ///   score = max(0, 1 - distance / 2)  →  [0, 1]
    func score(candidate: String, contextWords: [String]) -> Double {
        guard let embedding, !contextWords.isEmpty else { return 0 }

        let candidateLower = candidate.lowercased()
        let recent = Array(contextWords.suffix(5))

        // Recency weights aligned to the tail (always suffix of allWeights).
        // 1 word → [0.45], 2 → [0.25, 0.45], 3 → [0.15, 0.25, 0.45], etc.
        let allWeights: [Double] = [0.05, 0.10, 0.15, 0.25, 0.45]
        let weights = Array(allWeights.suffix(recent.count))

        var weightedScore = 0.0
        var totalWeight   = 0.0

        for (i, word) in recent.enumerated() {
            let dist = embedding.distance(
                between: word.lowercased(),
                and: candidateLower,
                distanceType: .cosine
            )
            guard dist.isFinite, dist >= 0 else { continue }
            weightedScore += weights[i] * max(0.0, 1.0 - dist / 2.0)
            totalWeight   += weights[i]
        }

        return totalWeight > 0 ? weightedScore / totalWeight : 0
    }
}
