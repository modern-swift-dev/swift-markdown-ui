import Foundation
@testable import MarkdownUIEditor
import XCTest

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

@MainActor final class MarkdownImageAttachmentTests: XCTestCase {
    func testRelativeSourceResolvesAgainstBaseURLAndPreservesMetadata() {
        let metadata = MarkdownImageMetadata(
            source: "images/photo.png",
            title: "Photo",
            altText: "A descriptive alt"
        )
        let attachment = MarkdownImageAttachment(
            metadata: metadata,
            baseURL: URL(string: "https://example.com/docs/")
        )

        XCTAssertEqual(attachment.metadata, metadata)
        XCTAssertEqual(attachment.resolvedURL?.absoluteString, "https://example.com/docs/images/photo.png")
    }

    func testMetadataChangeCallbackIncludesAltSourceAndTitle() {
        var received: MarkdownImageMetadata?
        let attachment = MarkdownImageAttachment(
            metadata: MarkdownImageMetadata(source: "old.png", altText: "old"),
            onChange: { received = $0 }
        )
        let replacement = MarkdownImageMetadata(source: "new.png", title: "New", altText: "new alt")

        attachment.updateMetadata(replacement)

        XCTAssertEqual(attachment.metadata, replacement)
        XCTAssertEqual(received, replacement)
    }

    func testFormattedAltContentSurvivesEditingNeighboringText() throws {
        for source in ["![*cat*](cat.png) tail", "![a `b` and **c**](cat.png) tail", "![a \\* b](cat.png) tail"] {
            let document = MarkdownDocument(markdown: source)
            let projection = MarkdownProjectionBuilder().build(document: document)
            let content = NSMutableAttributedString(attributedString: projection.attributedString.attributedSubstring(
                from: NSRange(location: 0, length: projection.attributedString.length - 1)
            ))
            let attachment = try XCTUnwrap(content.attribute(.attachment, at: 0, effectiveRange: nil) as? MarkdownImageAttachment)
            XCTAssertEqual(attachment.metadata.altText, MarkdownImageMetadata.altText(for: attachment.altContent))
            content.append(NSAttributedString(string: "!"))
            let decoded = MarkdownDocument(blocks: [.paragraph(MarkdownAttributedInlineDecoder.decode(content))])
            XCTAssertEqual(decoded, MarkdownDocument(markdown: source + "!"))
            XCTAssertEqual(MarkdownDocument(markdown: decoded.markdown), decoded)
        }
    }

    func testImageMetadataChangesPreserveAltFormattingUntilAltTextChanges() throws {
        let document = MarkdownDocument(markdown: "![*cat*](cat.png)")
        let session = MarkdownEditingSession(document: document)
        let projection = session.projection
        let attachment = try XCTUnwrap(projection.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? MarkdownImageAttachment)
        XCTAssertEqual(attachment.metadata.altText, "cat")

        attachment.updateMetadata(.init(source: "new.png", title: "New", altText: "cat"))
        XCTAssertEqual(attachment.altContent, [.emphasis([.text("cat")])])
        XCTAssertEqual(session.document, MarkdownDocument(markdown: "![*cat*](new.png \"New\")"))

        attachment.updateMetadata(.init(source: "new.png", title: "New", altText: "*literal*"))
        XCTAssertEqual(attachment.altContent, [.text("*literal*")])
        XCTAssertEqual(session.document, MarkdownDocument(markdown: "![\\*literal\\*](new.png \"New\")"))
    }

    #if canImport(AppKit)
        func testAppKitViewProviderConstructsAccessibleImageView() throws {
            let attachment = MarkdownImageAttachment(
                metadata: MarkdownImageMetadata(source: "image.png", altText: "Diagram alt")
            )
            let contentStorage = NSTextContentStorage()
            let provider = try XCTUnwrap(
                attachment.viewProvider(
                    for: nil,
                    location: contentStorage.documentRange.location,
                    textContainer: nil
                )
            )

            XCTAssertTrue(provider is MarkdownImageAttachmentViewProvider)
            let view = try XCTUnwrap(provider.view)
            XCTAssertEqual(view.accessibilityLabel(), "Diagram alt")
            XCTAssertTrue(provider.tracksTextAttachmentViewBounds)
        }
    #elseif canImport(UIKit)
        func testUIKitViewProviderConstructsAccessibleImageView() throws {
            let attachment = MarkdownImageAttachment(
                metadata: MarkdownImageMetadata(source: "image.png", altText: "Diagram alt")
            )
            let contentStorage = NSTextContentStorage()
            let provider = try XCTUnwrap(
                attachment.viewProvider(
                    for: nil,
                    location: contentStorage.documentRange.location,
                    textContainer: nil
                )
            )

            XCTAssertTrue(provider is MarkdownImageAttachmentViewProvider)
            let view = try XCTUnwrap(provider.view)
            XCTAssertEqual(view.accessibilityLabel, "Diagram alt")
            XCTAssertTrue(provider.tracksTextAttachmentViewBounds)
        }
    #endif
}
