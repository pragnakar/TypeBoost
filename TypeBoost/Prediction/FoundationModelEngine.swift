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
/// Sendable conformance is required so implementations can be actor types.
protocol ContextualPredictionProvider: Sendable {
    /// Asynchronously returns up to `limit` contextual word completions.
    func predict(context: TypingContext, limit: Int) async -> [String]
    /// Predicts the most likely next word(s) after a completed sentence fragment.
    func predictNextWord(context: TypingContext) async -> [String]
    /// Drops cached sessions so the next call starts with a fresh context window.
    /// Call when the user switches apps or resets typing context.
    func resetSessions() async
    /// Whether the provider is available on the current system.
    var isAvailable: Bool { get }
}

// MARK: – Stub (always available, for macOS < 26)

/// A no-op provider used when Foundation Models aren't available.
final class StubContextualProvider: ContextualPredictionProvider, @unchecked Sendable {
    var isAvailable: Bool { false }
    func predict(context: TypingContext, limit: Int) async -> [String] { [] }
    func predictNextWord(context: TypingContext) async -> [String] { [] }
    func resetSessions() async {}
}

// MARK: – Foundation Models Provider (macOS 26+)

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
actor FoundationModelEngine: ContextualPredictionProvider {

    private let model = SystemLanguageModel.default

    /// Tracks consecutive guardrail violations. After too many in a row,
    /// we stop calling the FM for this session to avoid spamming.
    private var consecutiveGuardrailHits = 0
    private let maxConsecutiveGuardrailHits = 5

    /// System instructions shared by both sessions.
    /// Framing the task as a benign autocomplete utility reduces false
    /// guardrail triggers caused by ambiguous word combinations in the context.
    private static let sessionInstructions = Instructions(
        "You are a keyboard autocomplete assistant. " +
        "Your only job is to suggest likely next words or complete partial words to help users type faster. " +
        "Always respond with plain words only. Never add explanations, punctuation, or refusals."
    )

    /// Reusable sessions — created once and kept alive so the model carries
    /// prior turn context, giving better continuity within a typing session.
    /// Separate sessions for completion vs next-word keep their prompts independent.
    /// Nilled out on context reset; exceededContextWindowSize also forces a reset.
    private var completionSession: LanguageModelSession?
    private var nextWordSession: LanguageModelSession?

    func resetSessions() async {
        completionSession = nil
        nextWordSession = nil
        // Reset the guardrail counter so a new context (different app, topic, or
        // document) gets a clean slate. Without this, 5 hits in a medical/legal
        // context permanently disables FM for the rest of the session.
        consecutiveGuardrailHits = 0
    }

    // nonisolated: reads only the immutable `model` constant — safe without actor hop.
    nonisolated var isAvailable: Bool {
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
            if completionSession == nil { completionSession = LanguageModelSession(instructions: Self.sessionInstructions) }
            let response = try await completionSession!.respond(to: prompt, options: options)

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
                // Context window full — drop session so next call starts fresh.
                completionSession = nil
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

        // Limit to last 3 words — enough context for good predictions while
        // minimising the chance of an ambiguous phrase triggering safety guardrails.
        let sentence = context.previousWords.suffix(3).joined(separator: " ")
        let prompt = """
        Next word after: "\(sentence)"
        Reply with 3 likely next words, one per line, most likely first.
        Plain words only.
        """

        do {
            if nextWordSession == nil { nextWordSession = LanguageModelSession(instructions: Self.sessionInstructions) }
            let options = GenerationOptions(
                temperature: 0.2,
                maximumResponseTokens: 12  // ~3 words + newlines
            )
            let response = try await nextWordSession!.respond(to: prompt, options: options)

            // Parse: split on whitespace/newlines, strip non-letter chars, drop
            // single-char results (articles stripped of punctuation, etc.).
            let words = response.content
                .components(separatedBy: .whitespacesAndNewlines)
                .compactMap { token -> String? in
                    let w = token.filter { $0.isLetter || $0 == "'" }.lowercased()
                    return w.count > 1 ? w : nil
                }
                .prefix(3)

            guard !words.isEmpty else { return [] }
            consecutiveGuardrailHits = 0
            return Array(words)

        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                consecutiveGuardrailHits += 1
            case .exceededContextWindowSize:
                nextWordSession = nil
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
        // Only pass the last 2 words + partial. Reduces guardrail surface and latency.
        let recentWords = context.previousWords.suffix(2).joined(separator: " ")
        let partial = context.currentWord
        return "Complete: \"\(recentWords) \(partial)\" — one word only."
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
    ///
    /// Foundation Models (macOS 26 beta) is disabled until the API stabilises.
    /// The FoundationModelEngine implementation is preserved — re-enable by
    /// removing the early return below once Apple ships a stable release.
    static func makeProvider() -> ContextualPredictionProvider {
        // FM DISABLED: API is macOS 26 beta, unstable concurrency + guardrail spam.
        // Layer 1 (NSSpellChecker + bigram) handles all predictions in the meantime.
        return StubContextualProvider()

        // -- Re-enable when ready: --
        // #if canImport(FoundationModels)
        // if #available(macOS 26.0, *) {
        //     let engine = FoundationModelEngine()
        //     if engine.isAvailable { return engine }
        // }
        // #endif
        // return StubContextualProvider()
    }
}
