#if os(iOS)
import MarkdownUI
import SnapshotTesting
import SwiftUI
import Testing

extension SnapshotTests {
    @MainActor
    @Suite(.enabled(if: SnapshotTestSupport.supportsPhoneSnapshots, "Skipping on iPad")) struct MarkdownImageTests {
        private let layout = SwiftUISnapshotLayout.device(config: .iPhone8)

        @Test func failingImage() {
            let view = MarkdownView {
                #"""
                An image that fails to load:

                ![Unavailable image](http://[)

                ― Photo by André Spieker
                """#
            }
            .border(Color.accentColor)
            .padding()

            assertSnapshot(of: view, as: .image(layout: layout))
        }

        @Test func relativeImage() {
            let view = MarkdownView(baseURL: URL(string: "https://example.com/picsum/")) {
                #"""
                500x300 image:

                ![](237-500x300)

                ― Photo by André Spieker
                """#
            }
            .border(Color.accentColor)
            .padding()
            .markdownImageProvider(
                AssetImageProvider(
                    name: { url in
                        #expect(
                            URL(string: "237-500x300", relativeTo: URL(string: "https://example.com/picsum/"))
                                == url
                        )
                        return url.lastPathComponent
                    },
                    bundle: .module
                )
            )

            assertSnapshot(of: view, as: .image(layout: layout))
        }

        @Test func imageLink() {
            let view = MarkdownView {
                #"""
                A link that contains an image instead of text:

                [![](https://example.com/picsum/237-100x150)](https://example.com)

                ― Photo by André Spieker
                """#
            }
            .border(Color.accentColor)
            .padding()
            .markdownImageProvider(AssetImageProvider(bundle: .module))

            assertSnapshot(of: view, as: .image(layout: layout))
        }

        @Test func multipleImages() {
            let view = MarkdownView {
                #"""
                [![](https://example.com/picsum/237-100x150)](https://example.com)
                ![](https://example.com/picsum/237-125x75)
                ![](https://example.com/picsum/237-500x300)
                ![](https://example.com/picsum/237-100x150)\#u{20}\#u{20}
                ![](https://example.com/picsum/237-125x75)

                ― Photo by André Spieker
                """#
            }
            .border(Color.accentColor)
            .padding()
            .markdownImageProvider(AssetImageProvider(bundle: .module))

            assertSnapshot(of: view, as: .image(layout: layout))
        }

        @Test func multipleImagesSize() {
            let view = MarkdownView {
                #"""
                ![](https://example.com/picsum/237-100x150)
                ![](https://example.com/picsum/237-125x75)

                ― Photo by André Spieker
                """#
            }
            .border(Color.accentColor)
            .padding()
            .markdownImageProvider(AssetImageProvider(bundle: .module))

            assertSnapshot(of: view, as: .image(layout: layout))
        }

        @Test func colorScheme() {
            let content = """
            This image is contextualized for either dark or light mode:

            ![](https://example.com/picsum/237-100x150#gh-dark-mode-only)
            ![](https://example.com/picsum/237-125x75#gh-light-mode-only)

            ― Photo by André Spieker
            """

            let view = VStack {
                MarkdownView(content)
                    .background()
                    .colorScheme(.light)
                    .border(Color.accentColor)
                    .padding()
                MarkdownView(content)
                    .background()
                    .colorScheme(.dark)
                    .border(Color.accentColor)
                    .padding()
            }
            .markdownImageProvider(AssetImageProvider(bundle: .module))

            assertSnapshot(of: view, as: .image(layout: layout))
        }
    }
}
#endif
