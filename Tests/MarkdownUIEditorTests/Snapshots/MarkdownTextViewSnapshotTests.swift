#if os(iOS) || os(macOS)
import Foundation
@testable import MarkdownUIEditor
import SnapshotTesting
import XCTest

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
private typealias AttachmentHostView = UIView
#elseif os(macOS)
private typealias AttachmentHostView = NSView
#endif

@MainActor final class MarkdownTextViewSnapshotTests: XCTestCase {
    private var retainedHost: AnyObject?
    private var retainedObjects: [AnyObject] = []
    private var retainedImageAttachmentView: AttachmentHostView?

    func testRichDocumentVisuals() {
        let textView = makeTextView(document: Self.richDocument, height: 520)
        host(textView)
        prepareForSnapshot(textView)

        assertSnapshot(
            of: textView,
            as: .wait(for: 0.2, on: snapshotStrategy(height: 520)),
            named: "rich-document-\(platformName)",
            options: snapshotOptions
        )
    }

    func testInlineCodeVisuals() {
        assertDocumentSnapshot(
            "Use `MarkdownEditor` for rich Markdown editing.",
            named: "inline-code",
            height: 140
        )
    }

    func testCodeBlockVisuals() {
        assertDocumentSnapshot(
            """
            ```swift
            let editor = MarkdownEditor(markdown: $markdown)
            ```
            """,
            named: "code-block",
            height: 180
        )
    }

    func testOrderedListVisuals() {
        assertDocumentSnapshot(
            """
            1. Draft the release notes
            2. Review the changes
            3. Ship the release
            """,
            named: "ordered-list",
            height: 200
        )
    }

    func testUnorderedListVisuals() {
        assertDocumentSnapshot(
            """
            - Build the example apps
            - Run the snapshot tests
            - Check both platforms
            """,
            named: "unordered-list",
            height: 200
        )
    }

    func testTaskListVisuals() {
        assertDocumentSnapshot(
            """
            - [x] Implement rich editing
            - [ ] Review the native controls
            - [ ] Publish the release
            """,
            named: "task-list",
            height: 200
        )
    }

    func testBlockquoteVisuals() {
        assertDocumentSnapshot(
            "> Native text editing should preserve Markdown structure.",
            named: "blockquote",
            height: 160
        )
    }

    func testTableVisuals() {
        assertDocumentSnapshot(
            """
            | Format | Editing behavior |
            | --- | --- |
            | Strong | Bold text |
            | Link | A longer destination label that wraps when the available editor width cannot fit the complete cell content on one line |
            """,
            named: "table",
            height: 300
        )
    }

    func testNativeAttachmentVisuals() async throws {
        let hostView = try makeAttachmentHostView()
        let imageAttachmentView = try XCTUnwrap(retainedImageAttachmentView)
        for _ in 0 ..< 50 where !containsLoadedImage(in: imageAttachmentView) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(containsLoadedImage(in: imageAttachmentView))
        layout(hostView)

        assertSnapshot(
            of: hostView,
            as: attachmentSnapshotStrategy,
            named: "native-attachments-\(platformName)",
            options: snapshotOptions
        )
    }

    func testFocusedRichSelectionKeepsFormatting() {
        let textView = makeTextView(document: Self.focusDocument, height: 300)
        let range = (textView.markdownTextStorage.string as NSString).range(of: "bold selection")
        XCTAssertNotEqual(range.location, NSNotFound)
        focus(textView, selectedRange: range)
        prepareForSnapshot(textView)

        assertSnapshot(
            of: textView,
            as: .wait(for: 0.2, on: snapshotStrategy(height: 300)),
            named: "focused-rich-selection-\(platformName)",
            options: snapshotOptions
        )
    }
}

private extension MarkdownTextViewSnapshotTests {
    static let richDocument = MarkdownDocument(markdown: """
    # Always-rich editing

    A paragraph with **bold**, *emphasis*, ~~strikethrough~~, `inline code`, and a [link](https://example.com).

    > Block quotes stay visually distinct while the editor has focus.

    1. Ordered item
    2. Another ordered item

    - [x] Completed task
    - [ ] Pending task

    ```swift
    let message = "Markdown stays semantic"
    ```
    """)

    static let focusDocument = MarkdownDocument(markdown: """
    ## Editing a formatted run

    Typing inside this **bold selection** keeps the text bold. Delimiters remain hidden.

    The same behavior applies to *emphasis*, ~~strikethrough~~, `code`, and [links](https://example.com).
    """)

    var snapshotOptions: SnapshotAssertionOptions {
        SnapshotAssertionOptions(
            record: ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" ? .all : .missing
        )
    }

    var platformName: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #endif
    }

    func snapshotStrategy(height: CGFloat) -> Snapshotting<MarkdownTextView, MarkdownEditorPlatformImage> {
        #if os(iOS)
        Snapshotting<UIImage, UIImage>.image(
            options: ImageSnapshotOptions().requiringPerceptualPrecision(0.98)
        ).pullback { textView in
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            return UIGraphicsImageRenderer(bounds: textView.bounds, format: format).image { context in
                textView.layer.render(in: context.cgContext)
            }
        }
        #elseif os(macOS)
        .image(
            options: ImageSnapshotOptions().requiringPerceptualPrecision(0.98),
            size: CGSize(width: 620, height: height),
            isOpaque: true
        )
        #endif
    }

    func assertDocumentSnapshot(
        _ markdown: String,
        named name: String,
        height: CGFloat,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let textView = makeTextView(document: MarkdownDocument(markdown: markdown), height: height)
        host(textView)
        prepareForSnapshot(textView)

        assertSnapshot(
            of: textView,
            as: .wait(for: 0.2, on: snapshotStrategy(height: height)),
            named: "\(name)-\(platformName)",
            options: snapshotOptions,
            file: file,
            testName: testName,
            line: line
        )
    }

    func makeTextView(document: MarkdownDocument, height: CGFloat) -> MarkdownTextView {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.editorTheme = .basic
        textView.baseURL = URL(string: "snapshot://editor/")
        textView.imageProvider = SnapshotImageProvider()
        textView.document = document

        #if os(iOS)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        textView.backgroundColor = .white
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        textView.isScrollEnabled = false
        textView.overrideUserInterfaceStyle = .light
        #elseif os(macOS)
        textView.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        textView.backgroundColor = .white
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 16, height: 20)
        textView.appearance = NSAppearance(named: .aqua)
        #endif

        return textView
    }

    func host(_ textView: MarkdownTextView) {
        #if os(iOS)
        let window = UIWindow(frame: textView.frame)
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white
        viewController.view.addSubview(textView)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        retainedHost = window
        #elseif os(macOS)
        let window = NSWindow(
            contentRect: textView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        retainedHost = window
        #endif
    }

    func focus(_ textView: MarkdownTextView, selectedRange: NSRange) {
        host(textView)
        textView.selectedRange = selectedRange
        #if os(iOS)
        XCTAssertTrue(textView.becomeFirstResponder())
        #elseif os(macOS)
        guard let window = retainedHost as? NSWindow else {
            XCTFail("Missing snapshot window")
            return
        }
        textView.selectedRange = selectedRange
        XCTAssertTrue(window.makeFirstResponder(textView))
        #endif
    }

    func prepareForSnapshot(_ textView: MarkdownTextView) {
        if let textLayoutManager = textView.textLayoutManager {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        }
        #if os(iOS)
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        textView.setContentOffset(.zero, animated: false)
        #elseif os(macOS)
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()
        textView.selectedRange = textView.selectedRange.length == 0
            ? NSRange(location: 0, length: 0)
            : textView.selectedRange
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        textView.displayIfNeeded()
        #endif
    }

    var attachmentSnapshotStrategy: Snapshotting<AttachmentHostView, MarkdownEditorPlatformImage> {
        #if os(iOS)
        Snapshotting<UIImage, UIImage>.image(
            options: ImageSnapshotOptions()
                .requiringPixelPrecision(0.999)
                .requiringPerceptualPrecision(0.98)
        ).pullback { view in
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
                view.layer.render(in: context.cgContext)
            }
        }
        #elseif os(macOS)
        .image(
            options: ImageSnapshotOptions()
                .requiringPixelPrecision(0.999)
                .requiringPerceptualPrecision(0.98),
            size: CGSize(width: 620, height: 400),
            isOpaque: true
        )
        #endif
    }

    func makeAttachmentHostView() throws -> AttachmentHostView {
        let table = MarkdownTable(
            alignments: [.left, .right],
            header: MarkdownTableRow(cells: [
                MarkdownTableCell(content: [.text("Format")]),
                MarkdownTableCell(content: [.text("Editing view")])
            ]),
            rows: [
                MarkdownTableRow(cells: [
                    MarkdownTableCell(content: [.text("Strong")]),
                    MarkdownTableCell(content: [.text("Bold text")])
                ]),
                MarkdownTableRow(cells: [
                    MarkdownTableCell(content: [.text("Link")]),
                    MarkdownTableCell(content: [.text("Linked text")])
                ])
            ]
        )
        let contentStorage = NSTextContentStorage()
        let tableAttachment = MarkdownTableAttachment(table: table)
        let tableProvider = try XCTUnwrap(tableAttachment.viewProvider(
            for: nil,
            location: contentStorage.documentRange.location,
            textContainer: nil
        ))
        let imageAttachment = MarkdownImageAttachment(
            metadata: MarkdownImageMetadata(source: "image", altText: "Native image attachment"),
            baseURL: URL(string: "snapshot://editor/"),
            imageProvider: SnapshotImageProvider()
        )
        let imageProvider = try XCTUnwrap(imageAttachment.viewProvider(
            for: nil,
            location: contentStorage.documentRange.location,
            textContainer: nil
        ))
        let tableView = try XCTUnwrap(tableProvider.view)
        let imageView = try XCTUnwrap(imageProvider.view)
        retainedObjects = [contentStorage, tableAttachment, tableProvider, imageAttachment, imageProvider]
        retainedImageAttachmentView = imageView

        #if os(iOS)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        host.backgroundColor = .white
        tableView.frame = CGRect(x: 16, y: 20, width: 358, height: tableView.intrinsicContentSize.height)
        imageView.frame = CGRect(x: 75, y: 170, width: 240, height: 160)
        host.addSubview(tableView)
        host.addSubview(imageView)
        #elseif os(macOS)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 400))
        host.appearance = NSAppearance(named: .aqua)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.white.cgColor
        tableView.frame = NSRect(x: 16, y: 252, width: 300, height: tableView.intrinsicContentSize.height)
        imageView.frame = NSRect(x: 190, y: 40, width: 240, height: 160)
        host.addSubview(tableView)
        host.addSubview(imageView)
        #endif
        layout(host)
        return host
    }

    func layout(_ view: AttachmentHostView) {
        #if os(iOS)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #elseif os(macOS)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        #endif
    }

    func containsLoadedImage(in view: AttachmentHostView) -> Bool {
        #if os(iOS)
        if let imageView = view as? UIImageView, imageView.image != nil {
            return true
        }
        #elseif os(macOS)
        if let imageView = view as? NSImageView, imageView.image != nil {
            return true
        }
        #endif
        return view.subviews.contains { containsLoadedImage(in: $0) }
    }
}

@MainActor private final class SnapshotImageProvider: MarkdownEditorImageProvider {
    func image(for url: URL) async throws -> MarkdownEditorPlatformImage {
        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160))
        return renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 76, y: 36, width: 88, height: 88))
        }
        #elseif os(macOS)
        let image = NSImage(size: NSSize(width: 240, height: 160))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 160).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 76, y: 36, width: 88, height: 88)).fill()
        image.unlockFocus()
        return image
        #endif
    }
}
#endif
