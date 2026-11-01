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
    ///
    /// Images are decoded off the main actor at the resolution image attachments display them,
    /// while keeping the point size that native platform decoding reports. Downloads use a
    /// dedicated URL session with its own HTTP cache, limited to 20 MB in memory and 200 MB on
    /// disk, and a 15-second request timeout.
    @MainActor public final class MarkdownURLSessionImageProvider: MarkdownEditorImageProvider {
        let loader: MarkdownEditorImageLoader

        /// Creates the provider.
        ///
        /// Providers created this way share one bounded cache of decoded images, so editors
        /// showing the same image reuse it instead of each keeping its own copy.
        public init() {
            self.loader = MarkdownEditorImageLoader.shared
        }

        init(loader: MarkdownEditorImageLoader) {
            self.loader = loader
        }

        /// Downloads and decodes an image, reusing decoded images cached by this provider's loader.
        public func image(for url: URL) async throws -> MarkdownEditorPlatformImage {
            try await loader.image(for: url.absoluteURL)
        }

    }

    /// Errors raised by built-in image providers.
    public enum MarkdownEditorImageProviderError: Error, Hashable, Sendable {
        /// Downloaded data could not be decoded as an image.
        case invalidImageData
    }

    /// Owns an image attachment's request for its native views, retaining a completed image
    /// across detach/reattach cycles.
    @MainActor final class MarkdownImageViewLoader {
        let provider: (any MarkdownEditorImageProvider)?
        let url: URL?
        private var task: Task<Void, Never>?
        private var image: MarkdownEditorPlatformImage?
        /// The views waiting for the request in progress, by identity.
        private var waiting: [ObjectIdentifier: @MainActor (MarkdownEditorPlatformImage) -> Void] = [:]

        init(provider: (any MarkdownEditorImageProvider)?, url: URL?) {
            self.provider = provider
            self.url = url
        }

        deinit { task?.cancel() }

        /// Calls `onLoad` with the image once it is loaded, starting the request unless one is in progress.
        func start(for view: AnyObject, onLoad: @escaping @MainActor (MarkdownEditorPlatformImage) -> Void) {
            if let image {
                onLoad(image); return
            }
            guard let provider, let url else {
                return
            }
            waiting[ObjectIdentifier(view)] = onLoad
            guard task == nil else {
                return
            }
            task = Task { @MainActor [weak self] in
                do {
                    let image = try await provider.image(for: url)
                    try Task.checkCancellation()
                    guard let self else {
                        return
                    }
                    self.image = image
                    self.task = nil
                    let waiting = self.waiting.values
                    self.waiting = [:]
                    waiting.forEach { $0(image) }
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.task = nil
                    self?.waiting = [:]
                }
            }
        }

        /// Stops waiting for `view`, and cancels the request if no view waits for it on the next turn
        /// of the main actor. A view replacing this one, as when the attachment's text is replaced or
        /// a table cell is rendered again, waits in the same turn and keeps the request.
        func cancel(for view: AnyObject) {
            waiting[ObjectIdentifier(view)] = nil
            Task { @MainActor [weak self] in
                guard let self, self.waiting.isEmpty else {
                    return
                }
                self.task?.cancel()
                self.task = nil
            }
        }
    }

    /// Keeps an image attachment's loader while the URL and provider it loads with are unchanged.
    @MainActor final class MarkdownImageRequest {
        private var loader: MarkdownImageViewLoader?

        nonisolated init() {}

        func loader(provider: (any MarkdownEditorImageProvider)?, url: URL?) -> MarkdownImageViewLoader {
            if let loader, loader.provider === provider, loader.url == url {
                return loader
            }
            let loader = MarkdownImageViewLoader(provider: provider, url: url)
            self.loader = loader
            return loader
        }
    }

    /// A TextKit attachment that owns image metadata and creates a native image view.
    public final class MarkdownImageAttachment: NSTextAttachment, @unchecked Sendable {
        /// Native image views draw loaded images aspect-fit into this fixed size.
        static let imageViewSize = CGSize(width: 240, height: 160)

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
        /// The editor path reported by `onChange`, updated when earlier blocks change.
        var pathReference: EditorPathReference?
        /// Decides whether native views may request ``resolvedURL`` from ``imageProvider``.
        var imageLoadingPolicy = MarkdownEditorImageLoadingPolicy.allowAll

        /// The provider native views may request ``resolvedURL`` from, or `nil` when the policy blocks it.
        var permittedImageProvider: (any MarkdownEditorImageProvider)? {
            guard let url = resolvedURL, !imageLoadingPolicy.allows(url) else {
                return imageProvider
            }
            return nil
        }

        /// The request of this attachment's image. Native views share it, since TextKit
        /// creates a new view each time the attachment's text is replaced.
        let imageRequest = MarkdownImageRequest()

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
            let request = attachment.imageRequest
            let provider = attachment.permittedImageProvider
            let url = attachment.resolvedURL
            let imageView = MainActor.assumeIsolated {
                UIKitMarkdownImageView(altText: altText, loader: request.loader(provider: provider, url: url))
            }
            tracksTextAttachmentViewBounds = true
            view = imageView
        }
    }

    @MainActor private final class UIKitMarkdownImageView: UIView {
        private let imageView = UIImageView()
        private let altLabel = UILabel()
        private let loader: MarkdownImageViewLoader

        init(altText: String, loader: MarkdownImageViewLoader) {
            self.loader = loader
            super.init(frame: CGRect(origin: .zero, size: MarkdownImageAttachment.imageViewSize))
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
            // TextKit sets this view's frame, starting from its initial size.
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
                altLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                altLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                altLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            loadImage()
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                loader.cancel(for: self)
            } else {
                loadImage()
            }
        }

        private func loadImage() {
            loader.start(for: self) { [weak self] image in self?.show(image) }
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
            let request = attachment.imageRequest
            let provider = attachment.permittedImageProvider
            let url = attachment.resolvedURL
            let imageView = MainActor.assumeIsolated {
                AppKitMarkdownImageView(altText: altText, loader: request.loader(provider: provider, url: url))
            }
            tracksTextAttachmentViewBounds = true
            view = imageView
        }
    }

    @MainActor private final class AppKitMarkdownImageView: NSView {
        private let imageView = NSImageView()
        private let altLabel = NSTextField(labelWithString: "")
        private let loader: MarkdownImageViewLoader

        init(altText: String, loader: MarkdownImageViewLoader) {
            self.loader = loader
            super.init(frame: NSRect(origin: .zero, size: MarkdownImageAttachment.imageViewSize))
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
            // TextKit sets this view's frame, starting from its initial size.
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
                altLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                altLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                altLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            loadImage()
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                loader.cancel(for: self)
            } else {
                loadImage()
            }
        }

        private func loadImage() {
            loader.start(for: self) { [weak self] image in self?.show(image) }
        }

        func show(_ image: NSImage) {
            imageView.image = image
            altLabel.isHidden = true
        }
    }
#endif
// Creates an image attachment and configures its native view support.
// Restores an empty attachment from an archive. Metadata is not archived.
