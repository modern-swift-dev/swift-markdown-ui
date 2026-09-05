import SwiftUI

struct InlineText: View {
    @Environment(\.inlineImageProvider) private var inlineImageProvider
    @Environment(\.baseURL) private var baseURL
    @Environment(\.imageBaseURL) private var imageBaseURL
    @Environment(\.softBreakMode) private var softBreakMode
    @Environment(\.theme) private var theme

    @State private var inlineImages: [RawImageData: Image] = [:]

    private let inlines: [InlineNode]

    private struct ImageLoadID: Equatable {
        let inlines: [InlineNode]
        let baseURL: URL?
        let providerID: InlineImageProviderContext.ID
    }

    init(_ inlines: [InlineNode]) {
        self.inlines = inlines
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
            inlines: self.inlines,
            baseURL: self.imageBaseURL,
            providerID: self.inlineImageProvider.id
        )) {
            self.inlineImages = [:]
            let images = await Self.loadInlineImages(
                in: self.inlines,
                baseURL: self.imageBaseURL,
                imageProvider: self.inlineImageProvider.provider
            )
            guard !Task.isCancelled else {
                return
            }
            self.inlineImages = images
        }
    }

    static func loadInlineImages(
        in inlines: [InlineNode],
        baseURL: URL?,
        imageProvider: any InlineImageProvider
    ) async -> [RawImageData: Image] {
        let images = Set(inlines.inlineImageData())
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
