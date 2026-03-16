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
    /// Strategy: compute the minimum NLEmbedding distance between the
    /// candidate and the last N context words. Lower distance = more
    /// relevant. Convert to a 0–1 score where 1 = maximally relevant.
    ///
    /// NLEmbedding.distance returns values in [0, 2] for cosine distance.
    /// We clamp and invert: score = max(0, 1 - distance / 2).
    func score(candidate: String, contextWords: [String]) -> Double {
        guard let embedding, !contextWords.isEmpty else { return 0 }

        let candidateLower = candidate.lowercased()

        // Use the last 3 context words for efficiency.
        let recent = contextWords.suffix(3)

        var minDistance = 2.0  // max possible cosine distance
        for word in recent {
            let dist = embedding.distance(
                between: word.lowercased(),
                and: candidateLower,
                distanceType: .cosine
            )
            // NLEmbedding returns NaN or very large value for unknown words.
            if dist.isFinite && dist < minDistance {
                minDistance = dist
            }
        }

        // Convert distance to a 0–1 relevance score.
        // Cosine distance range is [0, 2]. We want:
        //   distance 0.0 → score 1.0 (identical meaning)
        //   distance 1.0 → score 0.5 (orthogonal)
        //   distance 2.0 → score 0.0 (opposite meaning)
        return max(0, 1.0 - minDistance / 2.0)
    }
}
