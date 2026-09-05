import Foundation

#if canImport(UIKit)
import UIKit

/// The image type returned by image providers on UIKit platforms.
public typealias MarkdownEditorPlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit

/// The image type returned by image providers on AppKit.
public typealias MarkdownEditorPlatformImage = NSImage
#endif

/// The Markdown fields that describe an image reference.
public struct MarkdownImageMetadata: Hashable, Sendable {
    /// Destination URL or relative path from the Markdown image syntax.
    public var source: String
    /// Optional Markdown image title.
    public var title: String?
    /// Alternative text shown for accessibility and loading fallback.
    public var altText: String

    /// Creates image metadata from its Markdown fields.
    public init(source: String, title: String? = nil, altText: String) {
        self.source = source
        self.title = title
        self.altText = altText
    }

    static func altText(for content: [MarkdownInline]) -> String {
        content.map { inline in
            switch inline {
                case let .text(value),
                     let .code(value),
                     let .html(value): value
                case .softBreak,
                     .lineBreak: "\n"
                case let .emphasis(children),
                     let .strong(children),
                     let .strikethrough(children),
                     let .link(_, _, children),
                     let .image(_, _, children): altText(for: children)
            }
        }.joined()
    }
}

#if canImport(UIKit) || canImport(AppKit)
@MainActor public protocol MarkdownEditorImageProvider: AnyObject, Sendable {
    /// Loads a platform image for a resolved image URL.
    func image(for url: URL) async throws -> MarkdownEditorPlatformImage
}

/// Loads remote image data with `URLSession` and decodes it as a platform image.
@MainActor public final class MarkdownURLSessionImageProvider: MarkdownEditorImageProvider {
    /// Creates the provider.
    public init() {}

    /// Downloads and decodes an image.
    public func image(for url: URL) async throws -> MarkdownEditorPlatformImage {
        let (data, _) = try await URLSession.shared.data(from: url)
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else {
            throw MarkdownEditorImageProviderError.invalidImageData
        }
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else {
            throw MarkdownEditorImageProviderError.invalidImageData
        }
        #endif
        return image
    }
}

/// Errors raised by built-in image providers.
public enum MarkdownEditorImageProviderError: Error, Hashable, Sendable {
    /// Downloaded data could not be decoded as an image.
    case invalidImageData
}

/// A TextKit attachment that owns image metadata and creates a native image view.
public final class MarkdownImageAttachment: NSTextAttachment, @unchecked Sendable {
    /// Current Markdown metadata for the attachment.
    public private(set) var metadata: MarkdownImageMetadata
    /// Original inline alt content, retained independently of its accessible text.
    var altContent: [MarkdownInline]
    /// Base URL used to resolve relative image destinations.
    public let baseURL: URL?
    /// Optional asynchronous loader for the resolved URL.
    public let imageProvider: (any MarkdownEditorImageProvider)?
    /// Callback invoked when a native view changes the image metadata.
    public var onChange: ((MarkdownImageMetadata) -> Void)?

    /// Absolute image URL after resolving `metadata.source` against `baseURL`.
    public var resolvedURL: URL? {
        URL(string: metadata.source, relativeTo: baseURL)?.absoluteURL
    }

    /// Creates an attachment from Markdown metadata and optional URL resolution support.
    public init(
        metadata: MarkdownImageMetadata,
        baseURL: URL? = nil,
        imageProvider: (any MarkdownEditorImageProvider)? = nil,
        onChange: ((MarkdownImageMetadata) -> Void)? = nil
    ) {
        self.metadata = metadata
        self.altContent = [.text(metadata.altText)]
        self.baseURL = baseURL
        self.imageProvider = imageProvider
        self.onChange = onChange
        super.init(data: nil, ofType: "com.modernswiftdev.markdown-ui-editor.url-image")
        allowsTextAttachmentView = true
        lineLayoutPadding = 2
    }

    /// Restores an empty attachment from an archive. Metadata is not archived.
    public required init?(coder: NSCoder) {
        self.metadata = MarkdownImageMetadata(source: "", altText: "")
        self.altContent = []
        self.baseURL = nil
        self.imageProvider = nil
        self.onChange = nil
        super.init(coder: coder)
        allowsTextAttachmentView = true
    }

    /// Replaces image metadata and notifies the projection owner when it changes.
    public func updateMetadata(_ metadata: MarkdownImageMetadata) {
        guard self.metadata != metadata else {
            return
        }
        if self.metadata.altText != metadata.altText {
            altContent = [.text(metadata.altText)]
        }
        self.metadata = metadata
        onChange?(metadata)
    }

    #if canImport(UIKit)
    /// Returns a UIKit attachment view provider for this image.
    override public func viewProvider(
        for parentView: UIView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        MarkdownImageAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }
    #elseif canImport(AppKit)
    /// Returns an AppKit attachment view provider for this image.
    override public func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        MarkdownImageAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }
    #endif
}
#endif

#if canImport(UIKit)
/// Creates the UIKit view for a `MarkdownImageAttachment` and starts image loading.
public final class MarkdownImageAttachmentViewProvider: NSTextAttachmentViewProvider {
    /// Creates and starts loading the native UIKit image view.
    override public func loadView() {
        guard let attachment = textAttachment as? MarkdownImageAttachment else {
            view = nil
            return
        }
        let altText = attachment.metadata.altText
        let provider = attachment.imageProvider
        let url = attachment.resolvedURL
        let imageView = MainActor.assumeIsolated {
            let imageView = UIKitMarkdownImageView(altText: altText)
            if let provider, let url {
                Task { @MainActor [weak imageView] in
                    guard let image = try? await provider.image(for: url) else {
                        return
                    }
                    imageView?.show(image)
                }
            }
            return imageView
        }
        tracksTextAttachmentViewBounds = true
        view = imageView
    }
}

@MainActor private final class UIKitMarkdownImageView: UIView {
    private let imageView = UIImageView()
    private let altLabel = UILabel()

    init(altText: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        isAccessibilityElement = true
        accessibilityLabel = altText
        accessibilityTraits = .image

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        altLabel.text = altText
        altLabel.textColor = .secondaryLabel
        altLabel.font = .preferredFont(forTextStyle: .caption1)
        altLabel.textAlignment = .center
        altLabel.numberOfLines = 2
        altLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(altLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 240),
            heightAnchor.constraint(equalToConstant: 160),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            altLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            altLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            altLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(_ image: UIImage) {
        imageView.image = image
        altLabel.isHidden = true
    }
}
#elseif canImport(AppKit)
/// Creates the AppKit view for a `MarkdownImageAttachment` and starts image loading.
public final class MarkdownImageAttachmentViewProvider: NSTextAttachmentViewProvider {
    /// Creates and starts loading the native AppKit image view.
    override public func loadView() {
        guard let attachment = textAttachment as? MarkdownImageAttachment else {
            view = nil
            return
        }
        let altText = attachment.metadata.altText
        let provider = attachment.imageProvider
        let url = attachment.resolvedURL
        let imageView = MainActor.assumeIsolated {
            let imageView = AppKitMarkdownImageView(altText: altText)
            if let provider, let url {
                Task { @MainActor [weak imageView] in
                    guard let image = try? await provider.image(for: url) else {
                        return
                    }
                    imageView?.show(image)
                }
            }
            return imageView
        }
        tracksTextAttachmentViewBounds = true
        view = imageView
    }
}

@MainActor private final class AppKitMarkdownImageView: NSView {
    private let imageView = NSImageView()
    private let altLabel = NSTextField(labelWithString: "")

    init(altText: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(altText)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        altLabel.stringValue = altText
        altLabel.textColor = .secondaryLabelColor
        altLabel.font = .preferredFont(forTextStyle: .caption1)
        altLabel.alignment = .center
        altLabel.maximumNumberOfLines = 2
        altLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(altLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 240),
            heightAnchor.constraint(equalToConstant: 160),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            altLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            altLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            altLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(_ image: NSImage) {
        imageView.image = image
        altLabel.isHidden = true
    }
}
#endif
// Creates an image attachment and configures its native view support.
// Restores an empty attachment from an archive. Metadata is not archived.
