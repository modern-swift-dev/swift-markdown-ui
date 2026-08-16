import SwiftUI

struct InlineText: View {
    @Environment(\.inlineImageProvider) private var inlineImageProvider
    @Environment(\.baseURL) private var baseURL
    @Environment(\.imageBaseURL) private var imageBaseURL
    @Environment(\.softBreakMode) private var softBreakMode
    @Environment(\.theme) private var theme

    @State private var inlineImages: [RawImageData: Image] = [:]

    private let inlines: [InlineNode]

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
        .task(id: self.inlines) {
            self.inlineImages = await Self.loadInlineImages(
                in: self.inlines,
                baseURL: self.imageBaseURL,
                imageProvider: self.inlineImageProvider
            )
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
            for image in images {
                guard let url = URL(string: image.source, relativeTo: baseURL) else {
                    continue
                }

                taskGroup.addTask {
                    do {
                        return (image, try await imageProvider.image(with: url, label: image.alt))
                    } catch {
                        return (image, nil)
                    }
                }
            }

            var inlineImages: [RawImageData: Image] = [:]

            for await (data, image) in taskGroup {
                if let image {
                    inlineImages[data] = image
                }
            }

            return inlineImages
        }
    }
}
