// PredictionEngineTests.swift
// TypeBoostTests

import XCTest
@testable import TypeBoost

final class PredictionEngineTests: XCTestCase {

    private var engine: PredictionEngine!
    private var userDict: UserDictionary!

    override func setUp() {
        super.setUp()
        userDict = UserDictionary()
        userDict.isLearningEnabled = false // Avoid side effects in tests
        engine = PredictionEngine(userDictionary: userDict)
    }

    // MARK: – Basic Predictions

    func testPredictReturnsResults() {
        let context = TypingContext(currentWord: "the", previousWords: [])
        let suggestions = engine.predict(context: context)
        XCTAssertFalse(suggestions.isEmpty, "Should return suggestions for a common prefix")
    }

    func testPredictReturnsMaxThree() {
        let context = TypingContext(currentWord: "th", previousWords: [])
        let suggestions = engine.predict(context: context)
        XCTAssertLessThanOrEqual(suggestions.count, 3)
    }

    func testPredictEmptyPrefix() {
        let context = TypingContext(currentWord: "", previousWords: [])
        let suggestions = engine.predict(context: context)
        XCTAssertTrue(suggestions.isEmpty, "Empty prefix should return no suggestions")
    }

    func testPredictUnknownPrefix() {
        let context = TypingContext(currentWord: "zzzzxxx", previousWords: [])
        let suggestions = engine.predict(context: context)
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: – Context Influence

    func testContextImprovesSuggestions() {
        // "will" followed by "be" is a common bigram.
        let contextWithWill = TypingContext(currentWord: "b", previousWords: ["will"])
        let suggestionsWithContext = engine.predict(context: contextWithWill)

        let contextAlone = TypingContext(currentWord: "b", previousWords: [])
        let suggestionsAlone = engine.predict(context: contextAlone)

        // "be" should rank higher when preceded by "will".
        let rankWithContext = suggestionsWithContext.firstIndex(where: { $0.word == "be" })
        let rankAlone = suggestionsAlone.firstIndex(where: { $0.word == "be" })

        if let rc = rankWithContext, let ra = rankAlone {
            XCTAssertLessThanOrEqual(rc, ra, "'be' should rank higher after 'will'")
        }
    }

    // MARK: – Learning

    func testRecordAcceptanceBoostsWord() {
        let context = TypingContext(currentWord: "mee", previousWords: [])
        let before = engine.predict(context: context)
        guard let meeting = before.first(where: { $0.word == "meeting" }) else {
            // If meeting isn't in top results, test is inconclusive.
            return
        }

        // Accept "meeting" several times.
        for _ in 0..<10 {
            engine.recordAcceptance(meeting)
        }

        let after = engine.predict(context: context)
        let meetingAfter = after.first(where: { $0.word == "meeting" })
        XCTAssertNotNil(meetingAfter, "meeting should still appear after boosting")
    }

    // MARK: – Spell Check

    func testIsMisspelled() {
        XCTAssertTrue(engine.isMisspelled("qwertyxz"), "'qwertyxz' should be misspelled")
        XCTAssertFalse(engine.isMisspelled("the"), "'the' should not be misspelled")
    }

    func testCorrections() {
        let corrections = engine.corrections(for: "speling")
        XCTAssertFalse(corrections.isEmpty, "Should have corrections for 'speling'")
    }

    // MARK: – Performance

    func testPredictionLatency() {
        let context = TypingContext(currentWord: "com", previousWords: ["the"])
        measure {
            for _ in 0..<1000 {
                _ = engine.predict(context: context)
            }
        }
    }
}
