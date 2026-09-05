@testable import MarkdownUI
import XCTest
#if os(macOS)
import AppKit
import SwiftUI
#endif

final class TaskListPreservationTests: XCTestCase {
    func testMixedBulletedListPreservesOrdinaryAndTaskItems() {
        let content = MarkdownContent("- ordinary\n- [x] done\n- [ ] todo")

        XCTAssertEqual(content.blocks, [
            .bulletedList(isTight: true, items: [
                .init(children: [.paragraph(content: [.text("ordinary")])]),
                .init(children: [.paragraph(content: [.text("done")])], isCompleted: true),
                .init(children: [.paragraph(content: [.text("todo")])], isCompleted: false)
            ])
        ])
        XCTAssertEqual(content.renderMarkdown(), "  - ordinary\n- [x] done\n- [ ] todo")
        XCTAssertEqual(content.renderHTML(), """
        <ul>
        <li>ordinary</li>
        <li><input type="checkbox" checked="" disabled="" /> done</li>
        <li><input type="checkbox" disabled="" /> todo</li>
        </ul>

        """)
        XCTAssertEqual(MarkdownContent(content.renderMarkdown()), content)
    }

    func testOrderedTaskListPreservesStartAndCompletion() {
        let content = MarkdownContent("3. [ ] todo\n4. [x] done")

        XCTAssertEqual(content.blocks, [
            .numberedList(isTight: true, start: 3, items: [
                .init(children: [.paragraph(content: [.text("todo")])], isCompleted: false),
                .init(children: [.paragraph(content: [.text("done")])], isCompleted: true)
            ])
        ])
        XCTAssertEqual(content.renderMarkdown(), "3.  [ ] todo\n4.  [x] done")
        XCTAssertEqual(content.renderPlainText(), "3.  [ ] todo\n4.  [x] done")
        XCTAssertEqual(content.renderHTML(), """
        <ol start="3">
        <li><input type="checkbox" disabled="" /> todo</li>
        <li><input type="checkbox" checked="" disabled="" /> done</li>
        </ol>

        """)
        XCTAssertEqual(MarkdownContent(content.renderMarkdown()), content)
    }

    func testMixedOrderedListPreservesOrdinaryAndTaskItems() {
        let content = MarkdownContent("5. ordinary\n6. [ ] todo\n7. [x] done")
        XCTAssertEqual(content.renderMarkdown(), "5.  ordinary\n6.  [ ] todo\n7.  [x] done")
        XCTAssertTrue(content.renderHTML().contains("<li>ordinary</li>"))
        XCTAssertEqual(MarkdownContent(content.renderMarkdown()), content)
    }

    func testNestedListRewritesPreserveTaskMetadata() {
        let content = MarkdownContent(blocks: [.blockquote(children: [
            .bulletedList(isTight: true, items: [
                .init(children: [.paragraph(content: [.text("ordinary")])]),
                .init(children: [.paragraph(content: [.text("done")])], isCompleted: true)
            ]),
            .numberedList(isTight: true, start: 3, items: [
                .init(children: [.paragraph(content: [.text("todo")])], isCompleted: false)
            ])
        ])])
        let blockRewrite = content.blocks.rewrite { (block: BlockNode) in [block] }
        let inlineRewrite = content.blocks.rewrite { (inline: InlineNode) in [inline] }

        XCTAssertEqual(blockRewrite, content.blocks)
        XCTAssertEqual(inlineRewrite, content.blocks)
    }

    func testNestedOrderedTaskSerializationPreservesNumbersAndCompletion() {
        let innerList = BlockNode.numberedList(isTight: true, start: 7, items: [
            .init(children: [.paragraph(content: [
                .link(destination: "https://example.com", children: [.emphasis(children: [.text("inner")])])
            ])], isCompleted: true),
            .init(children: [.paragraph(content: [.text("ordinary")])])
        ])
        let content = MarkdownContent(blocks: [.blockquote(children: [
            .numberedList(isTight: true, start: 3, items: [
                .init(children: [
                    .paragraph(content: [.strong(children: [.text("outer")])]),
                    .bulletedList(isTight: true, items: [
                        .init(children: [
                            .paragraph(content: [.text("ordinary")]),
                            .blockquote(children: [innerList])
                        ])
                    ])
                ], isCompleted: false),
                .init(children: [.paragraph(content: [.text("ordinary")])])
            ])
        ])])
        let markdown = content.renderMarkdown()
        let plainText = content.renderPlainText()
        let html = content.renderHTML()

        XCTAssertTrue(markdown.contains("3.  [ ] **outer**"), markdown)
        XCTAssertTrue(markdown.contains("7.  [x] [*inner*](https://example.com)"), markdown)
        XCTAssertTrue(markdown.contains("8.  ordinary"), markdown)
        XCTAssertTrue(plainText.contains("3.  [ ] outer"), plainText)
        XCTAssertTrue(plainText.contains("7.  [x] inner"), plainText)
        XCTAssertTrue(html.contains("<ol start=\"7\">"))
        XCTAssertTrue(html.contains("<input type=\"checkbox\" checked=\"\" disabled=\"\" />"))
        XCTAssertTrue(html.contains("<em>inner</em>"))
    }

    #if os(macOS)
    @MainActor func testOrderedTasksRenderBothNumbersAndCheckboxes() async throws {
        let markers = RecordedListMarkers()
        let view = MarkdownView("3. [ ] todo\n4. [x] done\n5. ordinary")
            .markdownBlockStyle(\.numberedListMarker) { configuration in
                markers.numberedMarker(configuration.itemNumber)
            }
            .markdownBlockStyle(\.taskListMarker) { configuration in
                markers.taskMarker(configuration.isCompleted)
            }
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hostingView
        defer { window.contentView = nil }
        hostingView.layoutSubtreeIfNeeded()
        for _ in 0 ..< 100 {
            if markers.numbers == [3, 4, 5], markers.completion == [false, true] {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(markers.numbers, [3, 4, 5])
        XCTAssertEqual(markers.completion, [false, true])
    }
    #endif
}

#if os(macOS)
@MainActor private final class RecordedListMarkers {
    var numbers: Set<Int> = []
    var completion: Set<Bool> = []

    func numberedMarker(_ number: Int) -> Text {
        numbers.insert(number)
        return Text("\(number).")
    }

    func taskMarker(_ isCompleted: Bool) -> Text {
        completion.insert(isCompleted)
        return Text(isCompleted ? "[x]" : "[ ]")
    }
}
#endif
