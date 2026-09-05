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

    func testEvictsInInsertionOrder() {
        let base = CountingHighlighter()
        let cached = base.cached(maximumEntryCount: 2)
        for code in ["one", "two", "one", "three", "two"] {
            _ = cached.highlightCode(code, language: nil)
        }
        XCTAssertEqual(base.callCount, 3)
        _ = cached.highlightCode("one", language: nil)
        XCTAssertEqual(base.callCount, 4)
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
