import MarkdownUI
import SwiftUI
import XCTest
#if os(iOS) || os(macOS)
    import SnapshotTesting
#endif

/// Renders a document containing every block and inline type with each built-in theme in light and dark.
@MainActor final class ThemeBlockCoverageTests: XCTestCase {
    private static let width: CGFloat = 480
    private static let height: CGFloat = 1350

    private static let themes: [(name: String, theme: Theme)] = [
        ("basic", .basic), ("gitHub", .gitHub), ("docC", .docC)
    ]

    func testEveryBuiltInThemeLaysOutTheDocumentWithDistinctStyling() throws {
        var heights: [String: CGFloat] = [:]
        var bitmaps: [[UInt8]] = []
        for (name, theme) in Self.themes {
            for colorScheme in ColorScheme.allCases {
                let image = try RenderedImage.render(
                    MarkdownView(Self.document)
                        .markdownTheme(theme)
                        .markdownImageProvider(SwatchImageProvider())
                        .environment(\.colorScheme, colorScheme),
                    width: Self.width
                )
                XCTAssertGreaterThan(image.height, 400, "\(name) \(colorScheme)")
                heights["\(name)-\(colorScheme)"] = CGFloat(image.height)
                bitmaps.append(try RenderedImage.bytes(of: image))
            }
        }
        for (name, _) in Self.themes {
            XCTAssertEqual(heights["\(name)-light"], heights["\(name)-dark"], "Color scheme must not change the layout")
        }
        XCTAssertEqual(Set(bitmaps).count, bitmaps.count, "Every theme and color scheme looks different")
    }

    #if os(iOS) || os(macOS)
        func testBasicThemeRendersEveryBlockType() throws {
            try self.assertAllBlocks(theme: .basic, named: "basic")
        }

        func testGitHubThemeRendersEveryBlockType() throws {
            try self.assertAllBlocks(theme: .gitHub, named: "gitHub")
        }

        func testDocCThemeRendersEveryBlockType() throws {
            try self.assertAllBlocks(theme: .docC, named: "docC")
        }

        private func assertAllBlocks(theme: Theme, named name: String) throws {
            #if os(iOS)
                try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Skipping on iPad")
            #endif
            for colorScheme in ColorScheme.allCases {
                let scheme = colorScheme == .dark ? "dark" : "light"
                let view = MarkdownView(Self.document)
                    .markdownTheme(theme)
                    .markdownImageProvider(SwatchImageProvider())
                    .padding()
                    .frame(width: Self.width, height: Self.height, alignment: .topLeading)
                    .background(colorScheme == .dark ? Color.black : Color.white)
                    .colorScheme(colorScheme)
                #if os(iOS)
                    assertSnapshot(
                        of: view,
                        as: .image(
                            options: ImageSnapshotOptions().requiringPerceptualPrecision(0.98),
                            layout: .fixed(width: Self.width, height: Self.height),
                            settlingDelay: 0.2,
                            isOpaque: true
                        ),
                        named: "\(name)-\(scheme)",
                        options: .init(record: SnapshotTestSupport.configuration.record),
                        testName: "allBlocks"
                    )
                #else
                    assertSnapshot(
                        of: view,
                        as: .windowImage(
                            width: Self.width,
                            height: Self.height
                        ),
                        named: "\(name)-\(scheme)-macOS",
                        options: .init(record: SnapshotTestSupport.configuration.record),
                        testName: "allBlocks"
                    )
                #endif
            }
        }
    #endif

    private static let document = """
    # Heading 1
    ## Heading 2
    ### Heading 3
    #### Heading 4
    ##### Heading 5
    ###### Heading 6

    A paragraph with **strong**, *emphasis*, ~~strikethrough~~, `inline code` and a [link](https://example.com).

    > A blockquote with a second line to show the quote bar.
    >
    > > A nested blockquote.

    ```swift
    let greeting = "Hello"
    print(greeting)
    ```

    ![A block image](block-image)

    - A bulleted item
      - A nested bulleted item
        - A deeper bulleted item

    1. First numbered item
    2. Second numbered item
       1. A nested numbered item

    - [x] A completed task
    - [ ] An open task

    ---

    | Left | Center | Right |
    | :--- | :---: | ---: |
    | One | Two | Three |
    | Four | Five | Six |

    <div>An HTML block</div>
    """
}

private struct SwatchImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Image(systemName: "photo")
            .resizable()
            .scaledToFit()
            .frame(width: 72, height: 54)
    }
}
