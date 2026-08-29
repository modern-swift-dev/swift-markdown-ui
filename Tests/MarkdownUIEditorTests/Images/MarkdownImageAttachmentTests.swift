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
