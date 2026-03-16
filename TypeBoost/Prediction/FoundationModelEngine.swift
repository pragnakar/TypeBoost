// FoundationModelEngine.swift
// TypeBoost
//
// Optional Layer 2 prediction using Apple's on-device Foundation Models
// framework (available on macOS 26+). This runs asynchronously alongside
// the fast NSSpellChecker-based Layer 1, providing contextually richer
// suggestions when Apple Intelligence is available on the device.
//
// When Foundation Models are unavailable (older macOS, unsupported hardware,
// or user has disabled Apple Intelligence), this engine returns an empty
// result and the PredictionEngine falls back entirely to Layer 1.

import Foundation

// MARK: – Protocol

/// Abstraction so PredictionEngine doesn't depend on the concrete
/// Foundation Models import at compile time on older SDKs.
protocol ContextualPredictionProvider {
    /// Asynchronously returns up to `limit` contextual word completions.
    func predict(context: TypingContext, limit: Int) async -> [String]
    /// Predicts the most likely next word(s) after a completed sentence fragment.
    func predictNextWord(context: TypingContext) async -> [String]
    /// Whether the provider is available on the current system.
    var isAvailable: Bool { get }
}

// MARK: – Stub (always available, for macOS < 26)

/// A no-op provider used when Foundation Models aren't available.
final class StubContextualProvider: ContextualPredictionProvider {
    var isAvailable: Bool { false }
    func predict(context: TypingContext, limit: Int) async -> [String] { [] }
    func predictNextWord(context: TypingContext) async -> [String] { [] }
}

// MARK: – Foundation Models Provider (macOS 26+)

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
final class FoundationModelEngine: ContextualPredictionProvider {

    private let model = SystemLanguageModel.default

    /// Tracks consecutive guardrail violations. After too many in a row,
    /// we stop calling the FM for this session to avoid spamming.
    private var consecutiveGuardrailHits = 0
    private let maxConsecutiveGuardrailHits = 5

    var isAvailable: Bool {
        if case .available = model.availability {
            return true
        }
        return false
    }

    func predict(context: TypingContext, limit: Int) async -> [String] {
        guard isAvailable else { return [] }
        guard !context.currentWord.isEmpty else { return [] }
        guard consecutiveGuardrailHits < maxConsecutiveGuardrailHits else { return [] }

        let prompt = buildPrompt(context: context)
        let options = GenerationOptions(
            temperature: 0.3,
            maximumResponseTokens: 5
        )

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, options: options)

            let words = parseResponse(
                response.content,
                partial: context.currentWord,
                limit: limit
            )
            consecutiveGuardrailHits = 0
            return words

        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                // Expected for some inputs. Silently fall back to Layer 1.
                consecutiveGuardrailHits += 1
                return []
            case .exceededContextWindowSize:
                return []
            default:
                #if DEBUG
                NSLog("[TypeBoost] Foundation Model error: \(error)")
                #endif
                return []
            }
        } catch {
            // Non-GenerationError — silent fallback.
            return []
        }
    }

    // MARK: – Next-Word Prediction

    func predictNextWord(context: TypingContext) async -> [String] {
        guard isAvailable else { return [] }
        guard !context.previousWords.isEmpty else { return [] }
        guard consecutiveGuardrailHits < maxConsecutiveGuardrailHits else { return [] }

        let sentence = context.previousWords.suffix(6).joined(separator: " ")
        let prompt = """
        Next word prediction task.
        Sentence so far: "\(sentence)"
        What is the single most likely next word?
        Reply with one common English word only. No punctuation. No explanation.
        """

        do {
            let session = LanguageModelSession()
            let options = GenerationOptions(
                temperature: 0.2,
                maximumResponseTokens: 3
            )
            let response = try await session.respond(to: prompt, options: options)
            let word = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)
                .first?
                .filter { $0.isLetter || $0 == "'" }
                .lowercased() ?? ""

            guard !word.isEmpty, word.count > 1 else { return [] }
            consecutiveGuardrailHits = 0
            return [word]

        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                consecutiveGuardrailHits += 1
            default:
                break
            }
            return []
        } catch {
            return []
        }
    }

    // MARK: – Private

    private func buildPrompt(context: TypingContext) -> String {
        // Only pass the last 3 words + partial. Reduces guardrail surface and latency.
        let recentWords = context.previousWords.suffix(3).joined(separator: " ")
        let partial = context.currentWord
        return """
        Word completion task. Complete the partial word at the end.
        Previous words: \(recentWords)
        Partial word: \(partial)
        Complete the partial word only. Reply with one word. No punctuation. No explanation.
        """
    }

    private func parseResponse(_ raw: String, partial: String, limit: Int) -> [String] {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .first?
            .filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" }
            .lowercased() ?? ""

        guard !cleaned.isEmpty else { return [] }

        // Verify the response is actually a completion of the partial word.
        guard cleaned.hasPrefix(partial.lowercased()) else { return [] }

        return [cleaned]
    }
}
#endif

// MARK: – Factory

enum ContextualProviderFactory {
    /// Returns the best available contextual prediction provider.
    static func makeProvider() -> ContextualPredictionProvider {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let engine = FoundationModelEngine()
            if engine.isAvailable {
                #if DEBUG
                NSLog("[TypeBoost] Apple Foundation Models available — Layer 2 enabled.")
                #endif
                return engine
            }
        }
        #endif
        #if DEBUG
        NSLog("[TypeBoost] Foundation Models unavailable — using Layer 1 predictions only.")
        #endif
        return StubContextualProvider()
    }
}
