@testable import MarkdownUI
import SwiftUI
import XCTest

/// Checks that every style slot of a theme is applied to its block or inline type, whether it is set
/// through the `Theme` builder methods or through the `markdown…` environment modifiers.
@MainActor final class ThemeSlotTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        var names: Set<String> = []

        func record(_ name: String) {
            self.names.insert(name)
        }

        /// Records the name and returns the view unchanged, so it can be the result of a style body.
        func tag<Content: View>(_ name: String, _ view: Content) -> Content {
            self.record(name)
            return view
        }
    }

    private struct RecordingTextStyle: TextStyle {
        let name: String
        let calls: Calls

        func _collectAttributes(in attributes: inout AttributeContainer) {
            self.calls.record(self.name)
        }
    }

    private static let document = """
    # One
    ## Two
    ### Three
    #### Four
    ##### Five
    ###### Six

    Plain **strong** *emphasis* ~~strikethrough~~ `code` [link](https://example.com)

    > A quote

    ```swift
    let value = 1
    ```

    ![image](40x20)

    - bullet

    1. number

    - [x] task

    ---

    | a | b |
    | - | - |
    | c | d |
    """

    private static let blockSlots: Set<String> = [
        "heading1", "heading2", "heading3", "heading4", "heading5", "heading6", "paragraph", "blockquote",
        "codeBlock", "image", "list", "listItem", "taskListMarker", "bulletedListMarker", "numberedListMarker",
        "table", "tableCell", "thematicBreak"
    ]

    private static let textSlots: Set<String> = ["text", "code", "emphasis", "strong", "strikethrough", "link"]

    private func render(_ view: some View) throws {
        _ = try RenderedImage.render(
            view.markdownImageProvider(SwatchImageProvider()), width: 400
        )
    }

    func testThemeBuilderMethodsApplyEveryBlockStyle() throws {
        let calls = Calls()
        let theme = Theme()
            .heading1 { calls.tag("heading1", $0.label) }
            .heading2 { calls.tag("heading2", $0.label) }
            .heading3 { calls.tag("heading3", $0.label) }
            .heading4 { calls.tag("heading4", $0.label) }
            .heading5 { calls.tag("heading5", $0.label) }
            .heading6 { calls.tag("heading6", $0.label) }
            .paragraph { calls.tag("paragraph", $0.label) }
            .blockquote { calls.tag("blockquote", $0.label) }
            .codeBlock { calls.tag("codeBlock", $0.label) }
            .image { calls.tag("image", $0.label) }
            .list { calls.tag("list", $0.label) }
            .listItem { calls.tag("listItem", $0.label) }
            .taskListMarker { calls.tag("taskListMarker", Text($0.isCompleted ? "x" : "o")) }
            .bulletedListMarker { calls.tag("bulletedListMarker", Text("-\($0.listLevel)")) }
            .numberedListMarker { calls.tag("numberedListMarker", Text("\($0.itemNumber)")) }
            .table { calls.tag("table", $0.label) }
            .tableCell { calls.tag("tableCell", $0.label) }
            .thematicBreak { calls.tag("thematicBreak", Divider()) }
        try self.render(MarkdownView(Self.document).markdownTheme(theme))
        XCTAssertEqual(calls.names, Self.blockSlots)
    }

    func testThemeBuilderMethodsApplyEveryTextStyle() throws {
        let calls = Calls()
        let theme = Theme()
            .text { RecordingTextStyle(name: "text", calls: calls) }
            .code { RecordingTextStyle(name: "code", calls: calls) }
            .emphasis { RecordingTextStyle(name: "emphasis", calls: calls) }
            .strong { RecordingTextStyle(name: "strong", calls: calls) }
            .strikethrough { RecordingTextStyle(name: "strikethrough", calls: calls) }
            .link { RecordingTextStyle(name: "link", calls: calls) }
        try self.render(MarkdownView(Self.document).markdownTheme(theme))
        XCTAssertEqual(calls.names, Self.textSlots)
    }

    func testThemeBuilderMethodsWithMarkerStylesAndConfigurationOverloads() throws {
        let calls = Calls()
        let theme = Theme()
            .taskListMarker(BlockStyle<TaskListMarkerConfiguration> { _ in
                calls.tag("taskListMarker", Text("t"))
            })
            .bulletedListMarker(.dash)
            .numberedListMarker(.upperRoman)
            .bulletedListMarker { calls.tag("bulletedListMarker", Text("b\($0.listLevel)")) }
            .numberedListMarker { calls.tag("numberedListMarker", Text("n\($0.itemNumber)")) }
        try self.render(MarkdownView(Self.document).markdownTheme(theme))
        XCTAssertEqual(calls.names, ["taskListMarker", "bulletedListMarker", "numberedListMarker"])
    }

    func testEnvironmentModifiersApplyEveryBlockStyle() throws {
        let calls = Calls()
        let view = MarkdownView(Self.document)
            .markdownBlockStyle(\.heading1) { calls.tag("heading1", $0.label) }
            .markdownBlockStyle(\.heading2) { calls.tag("heading2", $0.label) }
            .markdownBlockStyle(\.heading3) { calls.tag("heading3", $0.label) }
            .markdownBlockStyle(\.heading4) { calls.tag("heading4", $0.label) }
            .markdownBlockStyle(\.heading5) { calls.tag("heading5", $0.label) }
            .markdownBlockStyle(\.heading6) { calls.tag("heading6", $0.label) }
            .markdownBlockStyle(\.paragraph) { calls.tag("paragraph", $0.label) }
            .markdownBlockStyle(\.blockquote) { calls.tag("blockquote", $0.label) }
            .markdownBlockStyle(\.codeBlock) { calls.tag("codeBlock", $0.label) }
            .markdownBlockStyle(\.image) { calls.tag("image", $0.label) }
            .markdownBlockStyle(\.list) { calls.tag("list", $0.label) }
            .markdownBlockStyle(\.listItem) { calls.tag("listItem", $0.label) }
            .markdownBlockStyle(\.table) { calls.tag("table", $0.label) }
            .markdownBlockStyle(\.tableCell) { calls.tag("tableCell", $0.label) }
            .markdownBlockStyle(\.thematicBreak) { calls.tag("thematicBreak", Divider()) }
            .markdownTaskListMarker(BlockStyle { _ in
                calls.tag("taskListMarker", Text("t"))
            })
            .markdownBulletedListMarker(BlockStyle { _ in
                calls.tag("bulletedListMarker", Text("b"))
            })
            .markdownNumberedListMarker(BlockStyle { _ in
                calls.tag("numberedListMarker", Text("n"))
            })
        try self.render(view)
        XCTAssertEqual(calls.names, Self.blockSlots)
    }

    func testEnvironmentModifiersApplyEveryTextStyle() throws {
        let calls = Calls()
        let view = MarkdownView(Self.document)
            .markdownTextStyle(\.text) { RecordingTextStyle(name: "text", calls: calls) }
            .markdownTextStyle(\.code) { RecordingTextStyle(name: "code", calls: calls) }
            .markdownTextStyle(\.emphasis) { RecordingTextStyle(name: "emphasis", calls: calls) }
            .markdownTextStyle(\.strong) { RecordingTextStyle(name: "strong", calls: calls) }
            .markdownTextStyle(\.strikethrough) { RecordingTextStyle(name: "strikethrough", calls: calls) }
            .markdownTextStyle(\.link) { RecordingTextStyle(name: "link", calls: calls) }
        try self.render(view)
        XCTAssertEqual(calls.names, Self.textSlots)
    }

    func testConfigurationsReachTheMarkerAndCellStyles() throws {
        let completions = Calls()
        let cells = Calls()
        let view = MarkdownView("- [x] done\n- [ ] open\n\n| a | b |\n| - | - |\n| c | d |")
            .markdownTaskListMarker(BlockStyle { configuration in
                completions.tag(configuration.isCompleted ? "done" : "open", Text("t"))
            })
            .markdownBlockStyle(\.tableCell) { configuration in
                cells.tag("\(configuration.row),\(configuration.column)", configuration.label)
            }
        try self.render(view)
        XCTAssertEqual(completions.names, ["done", "open"])
        XCTAssertEqual(cells.names, ["0,0", "0,1", "1,0", "1,1"])
    }
}

private struct SwatchImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Color.pureRed.frame(width: 40, height: 20)
    }
}
