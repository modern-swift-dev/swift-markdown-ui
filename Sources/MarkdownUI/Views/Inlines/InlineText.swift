import SwiftUI

struct InlineText: View {
    @Environment(\.inlineImageProvider) private var inlineImageProvider
    @Environment(\.imageLoadingPolicy) private var imageLoadingPolicy
    @Environment(\.baseURL) private var baseURL
    @Environment(\.imageBaseURL) private var imageBaseURL
    @Environment(\.softBreakMode) private var softBreakMode
    @Environment(\.theme) private var theme

    @State private var inlineImages: [RawImageData: Image] = [:]
    @State private var imageLoadID: ImageLoadID?

    private let inlines: [InlineNode]
    private let imageData: Set<RawImageData>
    private let hasLinkedImages: Bool

    private struct ImageLoadID: Equatable {
        let images: Set<RawImageData>
        let baseURL: URL?
        let providerID: InlineImageProviderContext.ID
    }

    init(_ inlines: [InlineNode]) {
        self.inlines = inlines
        self.imageData = inlines.inlineImageDataSet()
        self.hasLinkedImages = Self.containsLinkedImage(inlines)
    }

    var body: some View {
        TextStyleAttributesReader { attributes in
            self.inlines.renderText(
                baseURL: self.baseURL,
                textStyles: .init(
                    code: self.theme.code,
                    emphasis: self.theme.emphasis,
                    strong: self.theme.strong,
                    strikethrough: self.theme.strikethrough,
                    link: self.theme.link
                ),
                images: self.inlineImages,
                softBreakMode: self.softBreakMode,
                attributes: attributes
            )
        }
        .modifier(InlineImageLinksOverlay(isEnabled: self.hasLinkedImages))
        .task(id: ImageLoadID(
            images: self.imageData,
            baseURL: self.imageBaseURL,
            providerID: self.inlineImageProvider.id
        )) {
            guard !Task.isCancelled else {
                return
            }
            let loadID = ImageLoadID(
                images: self.imageData,
                baseURL: self.imageBaseURL,
                providerID: self.inlineImageProvider.id
            )
            if self.imageLoadID?.baseURL != loadID.baseURL
                || self.imageLoadID?.providerID != loadID.providerID {
                self.inlineImages = [:]
            } else if self.inlineImages.keys.contains(where: { !loadID.images.contains($0) }) {
                self.inlineImages = self.inlineImages.filter { loadID.images.contains($0.key) }
            }
            self.imageLoadID = loadID
            let missingImages = loadID.images.subtracting(self.inlineImages.keys)
            guard !missingImages.isEmpty else {
                return
            }
            let images = await Self.loadInlineImages(
                images: missingImages,
                baseURL: self.imageBaseURL,
                imageProvider: self.inlineImageProvider.provider,
                imageLoadingPolicy: self.imageLoadingPolicy
            )
            guard !Task.isCancelled, self.imageLoadID == loadID else {
                return
            }
            if !images.isEmpty {
                self.inlineImages.merge(images) { _, new in new }
            }
        }
    }

    private static func containsLinkedImage(_ inlines: [InlineNode], insideLink: Bool = false) -> Bool {
        inlines.contains { inline in
            switch inline {
                case .image:
                    insideLink
                case let .link(_, children):
                    containsLinkedImage(children, insideLink: true)
                default:
                    containsLinkedImage(inline.children, insideLink: insideLink)
            }
        }
    }

    static func loadInlineImages(
        in inlines: [InlineNode],
        baseURL: URL?,
        imageProvider: any InlineImageProvider,
        imageLoadingPolicy: ImageLoadingPolicy = .allowAll
    ) async -> [RawImageData: Image] {
        await loadInlineImages(
            images: inlines.inlineImageDataSet(),
            baseURL: baseURL,
            imageProvider: imageProvider,
            imageLoadingPolicy: imageLoadingPolicy
        )
    }

    private static func loadInlineImages(
        images: Set<RawImageData>,
        baseURL: URL?,
        imageProvider: any InlineImageProvider,
        imageLoadingPolicy: ImageLoadingPolicy
    ) async -> [RawImageData: Image] {
        guard !images.isEmpty else {
            return [:]
        }

        return await withTaskGroup(of: (RawImageData, Image?).self) { taskGroup in
            var pending = images.makeIterator()
            func enqueueNext() {
                guard !Task.isCancelled else {
                    return
                }
                while let image = pending.next() {
                    // Blocked images are never requested and keep rendering their alt text.
                    guard let url = URL(string: image.source, relativeTo: baseURL),
                          imageLoadingPolicy.allows(url) else {
                        continue
                    }
                    taskGroup.addTask {
                        do {
                            try Task.checkCancellation()
                            return (image, try await imageProvider.image(with: url, label: image.alt))
                        } catch {
                            return (image, nil)
                        }
                    }
                    return
                }
            }
            // Bound task creation as well as the default provider's shared network/decode work.
            for _ in 0 ..< 4 {
                enqueueNext()
            }

            var inlineImages: [RawImageData: Image] = [:]

            for await (data, image) in taskGroup {
                enqueueNext()
                if let image {
                    inlineImages[data] = image
                }
            }

            return inlineImages
        }
    }
}

/// Text drops link attributes from images, so loaded images inside links get a link button on top.
private struct InlineImageLinksOverlay: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if self.isEnabled {
            content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                InlineImageLinks(layouts: layouts)
            }
        } else {
            content
        }
    }
}

private struct InlineImageLinks: View {
    private struct Placement {
        let link: InlineImageLink
        let frame: CGRect
    }

    @Environment(\.openURL) private var openURL

    let layouts: Text.LayoutKey.Value

    var body: some View {
        GeometryReader { proxy in
            let placements = self.placements(in: proxy)
            ForEach(placements.indices, id: \.self) { index in
                let placement = placements[index]
                Button {
                    self.openURL(placement.link.url)
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(placement.link.label)
                .accessibilityAddTraits(.isLink)
                .frame(width: placement.frame.width, height: placement.frame.height)
                .position(x: placement.frame.midX, y: placement.frame.midY)
            }
        }
    }

    private func placements(in proxy: GeometryProxy) -> [Placement] {
        self.layouts.flatMap { anchoredLayout in
            let origin = proxy[anchoredLayout.origin]
            return anchoredLayout.layout.flatMap { line in
                line.compactMap { run in
                    run[InlineImageLink.self].map {
                        Placement(link: $0, frame: run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y))
                    }
                }
            }
        }
    }
}
