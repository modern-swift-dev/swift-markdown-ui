#if os(iOS) || os(macOS)
    import Foundation
    import MarkdownUI
    import SnapshotTesting
    import SwiftUI
    import XCTest

    @MainActor final class RenderingScenarioTests: XCTestCase {
        func testRiskBasedRenderingMatrix() throws {
            #if os(iOS)
                try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Skipping on iPad")
                let platform = "iOS"
            #else
                let platform = "macOS"
            #endif

            for scenario in RenderingScenario.auditMatrix {
                let view = ScrollView {
                    MarkdownView(scenario.markdown, baseURL: URL(string: "https://example.com/audit/"))
                        .markdownTheme(scenario.theme.value)
                        .markdownImageProvider(MatrixImageProvider())
                        .markdownInlineImageProvider(MatrixInlineImageProvider())
                        .padding()
                }
                .background(scenario.colorScheme == .dark ? Color.black : Color.white)
                .colorScheme(scenario.colorScheme)
                .environment(\.dynamicTypeSize, scenario.dynamicTypeSize)
                .environment(\.layoutDirection, scenario.layoutDirection)

                #if os(iOS)
                    assertSnapshot(
                        of: view,
                        as: .image(
                            options: ImageSnapshotOptions().requiringPerceptualPrecision(0.98),
                            layout: .fixed(width: scenario.width, height: scenario.height),
                            settlingDelay: 0.2,
                            isOpaque: true
                        ),
                        named: "\(scenario.name)-\(platform)",
                        options: .init(record: SnapshotTestSupport.configuration.record),
                        testName: "riskBasedRenderingMatrix"
                    )
                #else
                    assertSnapshot(
                        of: view,
                        as: .image(
                            options: ImageSnapshotOptions().requiringPerceptualPrecision(0.98),
                            layout: .fixed(width: scenario.width, height: scenario.height),
                            isOpaque: true
                        ),
                        named: "\(scenario.name)-\(platform)",
                        options: .init(record: SnapshotTestSupport.configuration.record),
                        testName: "riskBasedRenderingMatrix"
                    )
                #endif
            }
        }
    }

    private struct RenderingScenario: Sendable {
        enum AuditTheme: Sendable {
            case basic
            case docC
            case gitHub
            case custom

            var value: Theme {
                switch self {
                    case .basic:
                        .basic
                    case .docC:
                        .docC
                    case .gitHub:
                        .gitHub
                    case .custom:
                        Theme.basic
                            .link { ForegroundColor(.purple) }
                            .code {
                                FontFamilyVariant(.monospaced)
                                BackgroundColor(.purple.opacity(0.15))
                            }
                }
            }
        }

        let name: String
        let theme: AuditTheme
        let colorScheme: ColorScheme
        let dynamicTypeSize: DynamicTypeSize
        let layoutDirection: LayoutDirection
        let width: CGFloat
        let height: CGFloat
        let markdown: String

        static let auditMatrix: [Self] = [
            .init(
                name: "basic-light-narrow",
                theme: .basic,
                colorScheme: .light,
                dynamicTypeSize: .medium,
                layoutDirection: .leftToRight,
                width: 320,
                height: 760,
                markdown: representativeFixture
            ),
            .init(
                name: "github-dark-accessibility",
                theme: .gitHub,
                colorScheme: .dark,
                dynamicTypeSize: .accessibility2,
                layoutDirection: .leftToRight,
                width: 390,
                height: 900,
                markdown: stressFixture
            ),
            .init(
                name: "docc-light-rtl",
                theme: .docC,
                colorScheme: .light,
                dynamicTypeSize: .large,
                layoutDirection: .rightToLeft,
                width: 768,
                height: 820,
                markdown: representativeFixture
            ),
            .init(
                name: "custom-dark-wide",
                theme: .custom,
                colorScheme: .dark,
                dynamicTypeSize: .accessibility1,
                layoutDirection: .rightToLeft,
                width: 1024,
                height: 820,
                markdown: stressFixture
            )
        ]

        private static let representativeFixture = """
        # Rendering audit

        Text with **strong**, *emphasis*, ~~strike~~, `code`, and a [relative link](guide).

        > A block quote with a nested list:
        > 1. First item
        > 2. Second item

        - [x] Completed
        - [ ] Incomplete

        ![Deterministic block image](block-image)

        Text before *![Nested inline image](inline-image)* text after.

        | Left | Center | Right |
        | :--- | :---: | ---: |
        | Alpha | Bravo | Charlie |
        """

        private static let stressFixture = """
        ## Long and mixed content

        A deliberately long unbreakable value tests narrow layout behavior:
        `0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz`.

        1. Outer item
           - Nested item with **strong *emphasis***
             > Nested quotation with a 文字化け-resistant Unicode value: مرحبا 👩🏽‍💻

        ```swift
        let longValue = "The code block remains horizontally reachable without clipping."
        ```

        | Very wide first column | Very wide second column | Very wide third column |
        | --- | --- | --- |
        | One value that should remain reachable | Another value that should remain reachable | Final value |

        Missing inline image keeps its alt text: ![Missing illustration](missing-image).
        """
    }

    private struct MatrixImageProvider: ImageProvider {
        func makeImage(url: URL?) -> some View {
            Image(systemName: "photo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 54)
        }
    }

    private struct MatrixInlineImageProvider: InlineImageProvider {
        func image(with url: URL, label: String) async throws -> Image {
            guard url.lastPathComponent != "missing-image" else {
                throw MatrixImageError.missing
            }
            return Image(systemName: "star.fill")
        }
    }

    private enum MatrixImageError: Error {
        case missing
    }
#endif
