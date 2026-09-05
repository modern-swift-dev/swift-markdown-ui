import SwiftUI

struct InlineText: View {
    @Environment(\.inlineImageProvider) private var inlineImageProvider
    @Environment(\.baseURL) private var baseURL
    @Environment(\.imageBaseURL) private var imageBaseURL
    @Environment(\.softBreakMode) private var softBreakMode
    @Environment(\.theme) private var theme

    @State private var inlineImages: [RawImageData: Image] = [:]
    @State private var imageLoadID: ImageLoadID?

    private let inlines: [InlineNode]
    private let imageData: Set<RawImageData>

    private struct ImageLoadID: Equatable {
        let images: Set<RawImageData>
        let baseURL: URL?
        let providerID: InlineImageProviderContext.ID
    }

    init(_ inlines: [InlineNode]) {
        self.inlines = inlines
        self.imageData = inlines.inlineImageDataSet()
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
                imageProvider: self.inlineImageProvider.provider
            )
            guard !Task.isCancelled, self.imageLoadID == loadID else {
                return
            }
            if !images.isEmpty {
                self.inlineImages.merge(images) { _, new in new }
            }
        }
    }

    static func loadInlineImages(
        in inlines: [InlineNode],
        baseURL: URL?,
        imageProvider: any InlineImageProvider
    ) async -> [RawImageData: Image] {
        await loadInlineImages(images: inlines.inlineImageDataSet(), baseURL: baseURL, imageProvider: imageProvider)
    }

    private static func loadInlineImages(
        images: Set<RawImageData>,
        baseURL: URL?,
        imageProvider: any InlineImageProvider
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
                    guard let url = URL(string: image.source, relativeTo: baseURL) else {
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
