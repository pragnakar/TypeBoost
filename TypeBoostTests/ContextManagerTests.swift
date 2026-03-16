// ContextManagerTests.swift
// TypeBoostTests

import XCTest
@testable import TypeBoost

final class ContextManagerTests: XCTestCase {

    private var cm: ContextManager!

    override func setUp() {
        super.setUp()
        cm = ContextManager()
    }

    // MARK: – Basic Typing

    func testAppendCharacter() {
        cm.appendCharacter("h")
        cm.appendCharacter("e")
        cm.appendCharacter("l")
        XCTAssertEqual(cm.currentWord, "hel")
    }

    func testDeleteLastCharacter() {
        cm.appendCharacter("h")
        cm.appendCharacter("e")
        cm.deleteLastCharacter()
        XCTAssertEqual(cm.currentWord, "h")
    }

    func testDeleteOnEmptyWord() {
        cm.deleteLastCharacter() // Should not crash
        XCTAssertEqual(cm.currentWord, "")
    }

    // MARK: – Word Commit

    func testCommitWord() {
        cm.appendCharacter("h")
        cm.appendCharacter("i")
        cm.commitCurrentWord()

        XCTAssertEqual(cm.currentWord, "")
        XCTAssertEqual(cm.typingContext.previousWords, ["hi"])
    }

    func testMultipleWordsTracked() {
        let words = ["the", "quick", "brown", "fox"]
        for word in words {
            for char in word { cm.appendCharacter(char) }
            cm.commitCurrentWord()
        }
        XCTAssertEqual(cm.typingContext.previousWords, words)
    }

    func testPreviousWordsLimited() {
        for i in 0..<30 {
            for char in "word\(i)" { cm.appendCharacter(char) }
            cm.commitCurrentWord()
        }
        // Should keep at most 20 recent words.
        XCTAssertLessThanOrEqual(cm.typingContext.previousWords.count, 20)
    }

    // MARK: – Cancellation

    func testEscapeCancelsSuggestions() {
        cm.appendCharacter("m")
        cm.appendCharacter("e")
        cm.cancelCurrentWord()
        XCTAssertTrue(cm.isCancelled)
        XCTAssertEqual(cm.currentWord, "me") // Word not cleared
    }

    func testCancelResetsOnNewWord() {
        cm.appendCharacter("m")
        cm.cancelCurrentWord()
        cm.commitCurrentWord() // Completes the word
        cm.appendCharacter("n")
        XCTAssertFalse(cm.isCancelled)
    }

    func testDeleteAllResetsCancel() {
        cm.appendCharacter("a")
        cm.appendCharacter("b")
        cm.cancelCurrentWord()
        XCTAssertTrue(cm.isCancelled)

        cm.deleteLastCharacter()
        cm.deleteLastCharacter()
        XCTAssertFalse(cm.isCancelled)

        cm.appendCharacter("c")
        XCTAssertFalse(cm.isCancelled)
    }

    // MARK: – Accept Suggestion

    func testAcceptSuggestion() {
        cm.appendCharacter("m")
        cm.appendCharacter("e")
        cm.acceptSuggestion("meeting")

        XCTAssertEqual(cm.currentWord, "")
        XCTAssertEqual(cm.typingContext.previousWords.last, "meeting")
    }

    // MARK: – Reset

    func testReset() {
        cm.appendCharacter("x")
        cm.cancelCurrentWord()
        cm.reset()

        XCTAssertEqual(cm.currentWord, "")
        XCTAssertFalse(cm.isCancelled)
    }
}
