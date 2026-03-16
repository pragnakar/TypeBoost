// SpellCheckerEngineTests.swift
// TypeBoostTests

import XCTest
@testable import TypeBoost

final class SpellCheckerEngineTests: XCTestCase {

    private var engine: SpellCheckerEngine!

    override func setUp() {
        super.setUp()
        engine = SpellCheckerEngine()
    }

    // MARK: – Completions

    func testCompletionsReturnResults() {
        let results = engine.completions(for: "hel", limit: 5)
        XCTAssertFalse(results.isEmpty, "Should return completions for a common prefix")
    }

    func testCompletionsRespectsLimit() {
        let results = engine.completions(for: "th", limit: 3)
        XCTAssertLessThanOrEqual(results.count, 3)
    }

    func testCompletionsStartWithPrefix() {
        let results = engine.completions(for: "app", limit: 10)
        for word in results {
            XCTAssertTrue(
                word.lowercased().hasPrefix("app"),
                "'\(word)' should start with 'app'"
            )
        }
    }

    func testCompletionsEmptyPrefix() {
        let results = engine.completions(for: "", limit: 5)
        XCTAssertTrue(results.isEmpty, "Empty prefix should return no completions")
    }

    func testCompletionsUnknownPrefix() {
        let results = engine.completions(for: "zzzzxqq", limit: 5)
        XCTAssertTrue(results.isEmpty)
    }

    func testCompletionsAreLongerThanPrefix() {
        let results = engine.completions(for: "mee", limit: 10)
        for word in results {
            XCTAssertGreaterThan(
                word.count, 3,
                "'\(word)' should be longer than the prefix 'mee'"
            )
        }
    }

    // MARK: – Spell Check

    func testCorrectWordNotMisspelled() {
        XCTAssertFalse(engine.isMisspelled("hello"))
        XCTAssertFalse(engine.isMisspelled("world"))
        XCTAssertFalse(engine.isMisspelled("the"))
    }

    func testMisspelledWordDetected() {
        XCTAssertTrue(engine.isMisspelled("qwertyxz"))
        XCTAssertTrue(engine.isMisspelled("bananananana"))
    }

    func testSingleCharNotMisspelled() {
        // Single characters are too short to check.
        XCTAssertFalse(engine.isMisspelled("a"))
        XCTAssertFalse(engine.isMisspelled("x"))
    }

    // MARK: – Corrections

    func testCorrectionsForMisspelledWord() {
        let corrections = engine.corrections(for: "speling")
        XCTAssertFalse(corrections.isEmpty, "Should suggest corrections for 'speling'")
        XCTAssertLessThanOrEqual(corrections.count, 3)
    }

    func testCorrectionsEmpty() {
        let corrections = engine.corrections(for: "")
        XCTAssertTrue(corrections.isEmpty)
    }

    // MARK: – Learning

    func testLearnAndUnlearnWord() {
        let testWord = "typeboosttestword\(Int.random(in: 1000...9999))"

        // Before learning, the word should be misspelled.
        XCTAssertTrue(engine.isMisspelled(testWord))

        // Learn it.
        engine.learnWord(testWord)
        XCTAssertFalse(engine.isMisspelled(testWord), "Learned word should not be misspelled")

        // Unlearn it.
        engine.unlearnWord(testWord)
        XCTAssertTrue(engine.isMisspelled(testWord), "Unlearned word should be misspelled again")
    }

    // MARK: – Performance

    func testCompletionPerformance() {
        measure {
            for _ in 0..<100 {
                _ = engine.completions(for: "th", limit: 3)
                _ = engine.completions(for: "com", limit: 3)
                _ = engine.completions(for: "mee", limit: 3)
            }
        }
    }
}
