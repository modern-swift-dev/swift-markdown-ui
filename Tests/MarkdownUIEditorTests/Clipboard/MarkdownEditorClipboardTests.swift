import Foundation
@testable import MarkdownUIEditor
import XCTest

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

@MainActor final class MarkdownEditorClipboardTests: XCTestCase {
    func testPayloadPrefersMarkdown() {
        let payload = MarkdownClipboardPayload(markdown: "**bold**", plainText: "bold")

        XCTAssertTrue(payload.prefersMarkdown)
        XCTAssertEqual(payload.preferredText, "**bold**")
    }

    #if canImport(AppKit)
        func testMarkdownAndPlainTextRoundTrip() throws {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("MarkdownEditorTests.\(UUID().uuidString)"))
            defer { pasteboard.clearContents() }

            MarkdownEditorClipboard.write(markdown: "**bold**", plainText: "bold", to: pasteboard)
            let payload = try XCTUnwrap(MarkdownEditorClipboard.read(from: pasteboard))

            XCTAssertEqual(payload.markdown, "**bold**")
            XCTAssertEqual(payload.plainText, "bold")
            XCTAssertEqual(payload.preferredText, "**bold**")
        }

        func testPlainTextOnlyPasteDoesNotInventMarkdownOrImageData() throws {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("MarkdownEditorTests.\(UUID().uuidString)"))
            defer { pasteboard.clearContents() }
            pasteboard.clearContents()
            pasteboard.setString("plain", forType: .string)

            let payload = try XCTUnwrap(MarkdownEditorClipboard.read(from: pasteboard))

            XCTAssertNil(payload.markdown)
            XCTAssertEqual(payload.preferredText, "plain")
            XCTAssertFalse(payload.prefersMarkdown)
        }
    #elseif canImport(UIKit)
        func testMarkdownAndPlainTextRoundTrip() throws {
            let name = UIPasteboard.Name("MarkdownEditorTests.\(UUID().uuidString)")
            let pasteboard = try XCTUnwrap(UIPasteboard(name: name, create: true))
            defer { UIPasteboard.remove(withName: name) }

            MarkdownEditorClipboard.write(markdown: "**bold**", plainText: "bold", to: pasteboard)
            let payload = try XCTUnwrap(MarkdownEditorClipboard.read(from: pasteboard))

            XCTAssertEqual(payload.markdown, "**bold**")
            XCTAssertEqual(payload.plainText, "bold")
            XCTAssertEqual(payload.preferredText, "**bold**")
        }

        func testPlainTextOnlyPasteDoesNotInventMarkdownOrImageData() throws {
            let name = UIPasteboard.Name("MarkdownEditorTests.\(UUID().uuidString)")
            let pasteboard = try XCTUnwrap(UIPasteboard(name: name, create: true))
            defer { UIPasteboard.remove(withName: name) }
            pasteboard.string = "plain"

            let payload = try XCTUnwrap(MarkdownEditorClipboard.read(from: pasteboard))

            XCTAssertNil(payload.markdown)
            XCTAssertEqual(payload.preferredText, "plain")
            XCTAssertFalse(payload.prefersMarkdown)
        }
    #endif
}
