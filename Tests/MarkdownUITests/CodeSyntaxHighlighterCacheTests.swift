@testable import MarkdownUI
import os
import SwiftUI
import XCTest

final class CodeSyntaxHighlighterCacheTests: XCTestCase {
    private struct CountingHighlighter: CodeSyntaxHighlighter {
        let calls = OSAllocatedUnfairLock(initialState: 0)

        func highlightCode(_ code: String, language: String?) -> Text {
            calls.withLock { $0 += 1 }
            return Text(verbatim: "\(language ?? "nil"):\(code)").bold()
        }

        var callCount: Int {
            calls.withLock { $0 }
        }
    }

    func testRepeatedInputsAndCopiesReuseExactResult() {
        let base = CountingHighlighter()
        let cached = base.cached()
        let copy = cached
        let first = cached.highlightCode("let value = 1", language: "swift")
        XCTAssertEqual(first, Text(verbatim: "swift:let value = 1").bold())
        XCTAssertEqual(copy.highlightCode("let value = 1", language: "swift"), first)
        XCTAssertEqual(base.callCount, 1)
    }

    func testLanguageAndCodeAreBothPartOfKey() {
        let base = CountingHighlighter()
        let cached = base.cached()
        for language in [nil, "", "swift", "python"] as [String?] {
            for code in ["one", "two"] {
                let expected = Text(verbatim: "\(language ?? "nil"):\(code)").bold()
                XCTAssertEqual(cached.highlightCode(code, language: language), expected)
                XCTAssertEqual(cached.highlightCode(code, language: language), expected)
            }
        }
        XCTAssertEqual(base.callCount, 8)
    }

    func testHitsRefreshRecencyBeforeEviction() {
        let base = CountingHighlighter()
        let cached = base.cached(maximumEntryCount: 2)
        // The hit on "one" makes "two" the least recently used entry.
        for code in ["one", "two", "one", "three", "one"] {
            _ = cached.highlightCode(code, language: nil)
        }
        XCTAssertEqual(base.callCount, 3)
        _ = cached.highlightCode("two", language: nil)
        XCTAssertEqual(base.callCount, 4)
        // "three" was used less recently than "one", so "two" replaced it.
        _ = cached.highlightCode("one", language: nil)
        XCTAssertEqual(base.callCount, 4)
        _ = cached.highlightCode("three", language: nil)
        XCTAssertEqual(base.callCount, 5)
    }

    func testRepeatedHitsKeepFrequentlyUsedEntryAcrossManyInsertions() {
        let base = CountingHighlighter()
        let cached = base.cached(maximumEntryCount: 3)
        _ = cached.highlightCode("hot", language: "swift")
        for index in 0 ..< 50 {
            _ = cached.highlightCode("cold \(index)", language: "swift")
            _ = cached.highlightCode("hot", language: "swift")
        }
        XCTAssertEqual(base.callCount, 51)
    }

    func testKeysCompareFullInputsWhenPrecomputedHashesMatch() {
        typealias Key = CodeSyntaxHighlighterCacheKey
        XCTAssertEqual(Key(code: "one", language: "swift"), Key(code: "one", language: "swift"))
        XCTAssertEqual(Key(code: "one", language: "swift").hashValue, Key(code: "one", language: "swift").hashValue)
        XCTAssertNotEqual(Key(code: "one", language: nil), Key(code: "one", language: ""))
        // A colliding hash must not make different inputs share a result.
        let colliding = [
            Key(code: "one", language: nil, precomputedHash: 7),
            Key(code: "two", language: nil, precomputedHash: 7),
            Key(code: "one", language: "swift", precomputedHash: 7)
        ]
        XCTAssertEqual(Set(colliding).count, 3)
        XCTAssertEqual(colliding[0], Key(code: "one", language: nil, precomputedHash: 7))
    }

    func testEvictionKeepsNewestEntriesAcrossMultipleRotations() {
        let base = CountingHighlighter()
        let cached = base.cached(maximumEntryCount: 3)

        for index in 0 ..< 20 {
            _ = cached.highlightCode("code \(index)", language: nil)
            let callsAfterInsertion = base.callCount
            for retained in max(0, index - 2) ... index {
                _ = cached.highlightCode("code \(retained)", language: nil)
            }
            XCTAssertEqual(base.callCount, callsAfterInsertion)
        }

        XCTAssertEqual(base.callCount, 20)
        _ = cached.highlightCode("code 16", language: nil)
        XCTAssertEqual(base.callCount, 21)
        _ = cached.highlightCode("code 17", language: nil)
        XCTAssertEqual(base.callCount, 22)
    }

    func testSingleEntryCapacityReplacesPreviousEntry() {
        let base = CountingHighlighter()
        let cached = base.cached(maximumEntryCount: 1)
        for code in ["one", "two", "three", "one"] {
            _ = cached.highlightCode(code, language: nil)
            let callsAfterInsertion = base.callCount
            _ = cached.highlightCode(code, language: nil)
            XCTAssertEqual(base.callCount, callsAfterInsertion)
        }
        XCTAssertEqual(base.callCount, 4)
    }

    func testConcurrentEvictionLeavesCacheReusable() {
        let base = CountingHighlighter()
        let cached = base.cached(maximumEntryCount: 8)
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            XCTAssertEqual(
                cached.highlightCode("code \(index)", language: "swift"),
                Text(verbatim: "swift:code \(index)").bold()
            )
        }
        XCTAssertEqual(base.callCount, 256)

        for index in 0 ..< 8 {
            _ = cached.highlightCode("retained \(index)", language: "swift")
        }
        let callsAfterRefilling = base.callCount
        for index in 0 ..< 8 {
            _ = cached.highlightCode("retained \(index)", language: "swift")
        }
        XCTAssertEqual(base.callCount, callsAfterRefilling)
    }

    func testAdmissionCountsUTF8CodeAndLanguageBytes() {
        let base = CountingHighlighter()
        let cached = base.cached(maximumSourceByteCount: 5)
        for _ in 0 ..< 2 {
            _ = cached.highlightCode("é", language: "abc") // Exactly five bytes.
            _ = cached.highlightCode("ééé", language: nil)
            _ = cached.highlightCode("é", language: "abcd")
            _ = cached.highlightCode("", language: "abcdef")
        }
        XCTAssertEqual(base.callCount, 7)
    }

    func testZeroCapacityBypassesCache() {
        let base = CountingHighlighter()
        let cached = base.cached(maximumEntryCount: 0)
        for _ in 0 ..< 2 {
            _ = cached.highlightCode("one", language: nil)
        }
        XCTAssertEqual(base.callCount, 2)
    }

    func testConcurrentMissesLeaveReusableEntries() {
        let base = CountingHighlighter()
        let cached = base.cached(maximumEntryCount: 8)
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            _ = cached.highlightCode("code \(index % 8)", language: "swift")
        }
        let callsAfterConcurrentRequests = base.callCount
        for index in 0 ..< 8 {
            XCTAssertEqual(
                cached.highlightCode("code \(index)", language: "swift"),
                Text(verbatim: "swift:code \(index)").bold()
            )
        }
        XCTAssertEqual(base.callCount, callsAfterConcurrentRequests)
        XCTAssertGreaterThanOrEqual(base.callCount, 8)
    }
}
