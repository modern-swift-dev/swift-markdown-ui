#if os(macOS)
import AppKit
@testable import MarkdownUIEditor
import XCTest

@MainActor final class MarkdownTableInsertionTests: XCTestCase {
    func testInsertedTableGetsCellFocus() throws {
        let view = MarkdownTextView(usingTextLayoutManager: true)
        view.document = MarkdownDocument(markdown: "abc")
        view.selectedRange = NSRange(location: 3, length: 0)
        view.perform(.insertTable(columns: 2, bodyRows: 1))
        let attachment = try XCTUnwrap(view.textStorage?.attribute(.attachment, at: 4, effectiveRange: nil) as? MarkdownTableAttachment)
        XCTAssertNotNil(attachment.controller.activeSelection)
    }
}
#endif
