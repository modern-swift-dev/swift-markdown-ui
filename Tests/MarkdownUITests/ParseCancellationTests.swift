@testable import MarkdownUI
import XCTest

final class ParseCancellationTests: XCTestCase {
    private let markdown = "first\n\nsecond\n\nthird\n\nfourth"

    func testParseCancelledBeforeBlockConversionConvertsNoBlocks() {
        var checkpoints: [ParseCheckpoint] = []

        XCTAssertThrowsError(try MarkdownContent(self.markdown, checkpoint: { checkpoint in
            checkpoints.append(checkpoint)
            throw CancellationError()
        })) { XCTAssert($0 is CancellationError) }

        // Every block is preceded by a checkpoint, so none was reached.
        XCTAssertEqual(checkpoints, [.parsed])
    }

    func testParseCancelledDuringConversionConvertsNoFurtherBlocks() {
        var checkpoints: [ParseCheckpoint] = []

        XCTAssertThrowsError(try MarkdownContent(self.markdown, checkpoint: { checkpoint in
            checkpoints.append(checkpoint)
            if checkpoint == .beforeBlock(2) {
                throw CancellationError()
            }
        }))

        XCTAssertEqual(checkpoints, [.parsed, .beforeBlock(0), .beforeBlock(1), .beforeBlock(2)])
    }

    func testParseCancelledBeforeTheImageScanNeverRunsIt() {
        var checkpoints: [ParseCheckpoint] = []

        XCTAssertThrowsError(try MarkdownContent("![](a.png#gh-light-mode-only)", checkpoint: { checkpoint in
            checkpoints.append(checkpoint)
            if checkpoint == .beforeImageScan {
                throw CancellationError()
            }
        }))

        XCTAssertEqual(checkpoints, [.parsed, .beforeBlock(0), .beforeImageScan])
    }

    func testParseWithoutCancellationEqualsTheSynchronousParse() throws {
        var checkpoints: [ParseCheckpoint] = []

        let content = try MarkdownContent(self.markdown, checkpoint: { checkpoints.append($0) })

        XCTAssertEqual(content, MarkdownContent(self.markdown))
        XCTAssertEqual(content.colorSchemeImageBlockIndices, MarkdownContent(self.markdown).colorSchemeImageBlockIndices)
        XCTAssertEqual(checkpoints, [.parsed, .beforeBlock(0), .beforeBlock(1), .beforeBlock(2), .beforeBlock(3), .beforeImageScan])
    }

    func testCancelledTaskStopsTheCancellableParse() async {
        let markdown = self.markdown
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await MarkdownContent(cancellableParsing: markdown)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled parse produced content")
        } catch {
            XCTAssert(error is CancellationError)
        }
    }

    func testUncancelledTaskParsesLikeTheSynchronousParse() async throws {
        let content = try await MarkdownContent(cancellableParsing: self.markdown)

        XCTAssertEqual(content, MarkdownContent(self.markdown))
    }

    func testPublicParsingStillRunsToCompletionWhenCancelled() async {
        let markdown = self.markdown
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await MarkdownContent(parsing: markdown)
        }
        task.cancel()

        let content = await task.value

        XCTAssertEqual(content, MarkdownContent(markdown))
    }
}
