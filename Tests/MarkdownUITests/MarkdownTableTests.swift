#if os(iOS)
import MarkdownUI
import SnapshotTesting
import SwiftUI
import Testing

extension SnapshotTests {
    @MainActor
    @Suite(.enabled(if: SnapshotTestSupport.supportsPhoneSnapshots, "Skipping on iPad")) struct MarkdownTableTests {
        private let imageOptions = ImageSnapshotOptions().requiringPerceptualPrecision(0.98)
        private let layout = SwiftUISnapshotLayout.device(config: .iPhone8)

        @Test func table() {
            let view = MarkdownView {
                #"""
                A table with some padding:

                | Command | Description |
                | --- | --- |
                | git status | List all new or modified files |
                | git diff | Show file differences that haven't been staged |
                """#
            }
            .padding()
            .border(Color.accentColor)

            assertSnapshot(
                of: view, as: .image(options: imageOptions, layout: layout)
            )
        }

        @Test func tableAlignment() {
            let view = MarkdownView {
                #"""
                A table with some padding:

                | Default    | Leading    | Center     | Trailing   |
                | ---        | :---       |    :---:   |       ---: |
                | git status | git status | git status | git status |
                | git diff   | git diff   | git diff   | git diff   |
                """#
            }
            .padding()
            .border(Color.accentColor)

            assertSnapshot(
                of: view, as: .image(options: imageOptions, layout: layout)
            )
        }

        @Test func tableWithImages() {
            let view = MarkdownView {
                #"""
                A table with some padding:

                | First Header  | Second Header |
                | --- | --- |
                | ![](https://example.com/picsum/237-100x150) | ![](https://example.com/picsum/237-125x75) |
                | ![](https://example.com/picsum/237-500x300) | ![](https://example.com/picsum/237-100x150) |

                ― Photo by André Spieker
                """#
            }
            .padding()
            .border(Color.accentColor)
            .markdownImageProvider(AssetImageProvider(bundle: .module))

            assertSnapshot(
                of: view, as: .image(options: imageOptions, layout: layout)
            )
        }

        @Test func emptyTable() {
            let view = MarkdownView {
                #"""
                A table with some padding:

                | First Header  | Second Header |
                | ------------- | ------------- |
                """#
            }
            .padding()
            .border(Color.accentColor)

            assertSnapshot(
                of: view, as: .image(options: imageOptions, layout: layout)
            )
        }

        @Test func tableSize() {
            let view = MarkdownView {
                #"""
                A table with some padding:

                | First Header  | Second Header |
                | ------------- | ------------- |
                | Content Cell  | Content Cell  |
                | Content Cell  | Content Cell  |
                """#
            }
            .padding()
            .border(Color.accentColor)

            assertSnapshot(
                of: view, as: .image(options: imageOptions, layout: layout)
            )
        }

        @Test func tableBackground() {
            let view = MarkdownView {
                #"""
                A table with some padding:

                | Command | Description |
                | --- | --- |
                | git status | List all new or modified files |
                | git diff | Show file differences that haven't been staged |
                """#
            }
            .padding()
            .border(Color.accentColor)
            .markdownBlockStyle(\.table) { configuration in
                configuration.label
                    .markdownMargin(top: .zero, bottom: .em(1))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(Color.clear, Color(.secondarySystemBackground), header: .mint)
                    )
            }

            assertSnapshot(
                of: view, as: .image(options: imageOptions, layout: layout)
            )
        }

        @Test func tableBorder() {
            let view = MarkdownView {
                #"""
                A table with some padding:

                | Command | Description |
                | --- | --- |
                | git status | List all new or modified files |
                | git diff | Show file differences that haven't been staged |
                """#
            }
            .padding()
            .border(Color.accentColor)
            .markdownBlockStyle(\.table) { configuration in
                configuration.label
                    .markdownMargin(top: .zero, bottom: .em(1))
                    .markdownTableBorderStyle(
                        .init(
                            .outsideBorders,
                            color: Color.mint,
                            strokeStyle: .init(lineWidth: 2, lineJoin: .round, dash: [4])
                        )
                    )
            }

            assertSnapshot(
                of: view, as: .image(options: imageOptions, layout: layout)
            )
        }
    }
}
#endif
