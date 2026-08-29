@testable import MarkdownUIEditor
import XCTest

final class MarkdownDocumentModelTests: XCTestCase {
    func testPublicModelStoresEveryHeadingLevel() {
        let blocks = MarkdownHeadingLevel.allCases.map { level in
            MarkdownBlock.heading(level: level, content: [.text("Heading \(level.rawValue)")])
        }

        XCTAssertEqual(MarkdownDocument(blocks: blocks).blocks, blocks)
    }

    func testListSupportsMixedTaskAndOrdinaryItems() {
        let list = MarkdownList(
            kind: .unordered,
            isTight: true,
            items: [
                MarkdownListItem(blocks: [.paragraph([.text("ordinary")])]),
                MarkdownListItem(taskState: .unchecked, blocks: [.paragraph([.text("todo")])]),
                MarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("done")])])
            ]
        )

        XCTAssertEqual(list.items.map(\.taskState), [nil, .unchecked, .checked])
    }

    func testPublicModelIsHashableAndSendable() async {
        let document = MarkdownDocument(blocks: [.paragraph([.text("safe")])])
        let values = Set([document, document])

        let transferred = await Task.detached { document }.value

        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(transferred, document)
    }
}
