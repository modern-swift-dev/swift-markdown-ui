#if os(macOS)
    import AppKit
    @testable import MarkdownUI
    import os
    import SwiftUI
    import XCTest

    @MainActor final class CodeBlockStyleTests: XCTestCase {
        func testCodeBlockCollectsTextStyleOnce() {
            let style = CountingStyle()
            let highlighter = HighlightedCode()
            let host = NSHostingView(rootView: CodeBlockView(fenceInfo: "swift", content: "let x = 1\n")
                .markdownTheme(Theme())
                .markdownCodeSyntaxHighlighter(highlighter)
                .markdownTextStyle { style })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()

            XCTAssertEqual(style.calls.withLock { $0 }, 1)
        }

        func testFontAndForegroundMatchSeparateReadersWithCustomHighlighting() throws {
            for foreground: Color? in [.orange, nil] {
                let highlighter = HighlightedCode()
                let actual = CodeBlockView(fenceInfo: "swift", content: "let x = 1\n")
                    .markdownTheme(Theme())
                    .markdownCodeSyntaxHighlighter(highlighter)
                    .markdownTextStyle {
                        FontSize(23)
                        FontFamilyVariant(.monospaced)
                        ForegroundColor(foreground)
                    }
                let expected = highlighter.highlightCode("let x = 1", language: "swift")
                    .textStyleFont()
                    .textStyleForegroundColor()
                    .markdownTextStyle {
                        FontSize(23)
                        FontFamilyVariant(.monospaced)
                        ForegroundColor(foreground)
                    }

                let actualImage = try render(actual)
                let expectedImage = try render(expected)
                XCTAssertEqual(actualImage.width, expectedImage.width)
                XCTAssertEqual(actualImage.height, expectedImage.height)
                XCTAssertEqual(try pixels(actualImage), try pixels(expectedImage))
            }
        }

        func testHighlighterWholeTextFontAndColorOverrideDefaults() throws {
            let highlighter = WholeTextStyleHighlighter()
            let actual = CodeBlockView(fenceInfo: "swift", content: "let x = 1\n")
                .markdownTheme(Theme())
                .markdownCodeSyntaxHighlighter(highlighter)
                .markdownTextStyle {
                    FontSize(23)
                    ForegroundColor(.orange)
                }
            let expected = highlighter.highlightCode("let x = 1", language: "swift")
                .textStyleFont()
                .textStyleForegroundColor()
                .markdownTextStyle {
                    FontSize(23)
                    ForegroundColor(.orange)
                }

            let actualImage = try render(actual)
            let expectedImage = try render(expected)
            XCTAssertEqual(actualImage.width, expectedImage.width)
            XCTAssertEqual(actualImage.height, expectedImage.height)
            XCTAssertEqual(try pixels(actualImage), try pixels(expectedImage))
        }

        private func render(_ view: some View) throws -> CGImage {
            let renderer = ImageRenderer(content: view.padding(4).fixedSize().environment(\.colorScheme, .light))
            renderer.scale = 1
            return try XCTUnwrap(renderer.cgImage)
        }

        private func pixels(_ image: CGImage) throws -> Data {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
        }
    }

    private struct CountingStyle: TextStyle {
        let calls = OSAllocatedUnfairLock(initialState: 0)

        func _collectAttributes(in attributes: inout AttributeContainer) {
            calls.withLock { $0 += 1 }
            attributes.foregroundColor = .orange
        }
    }

    private struct HighlightedCode: CodeSyntaxHighlighter {
        func highlightCode(_ code: String, language: String?) -> Text {
            Text(verbatim: language ?? "none").foregroundColor(.blue)
                + Text(verbatim: ": \(code)").bold()
        }
    }

    private struct WholeTextStyleHighlighter: CodeSyntaxHighlighter {
        func highlightCode(_ code: String, language: String?) -> Text {
            Text(verbatim: code).font(.system(size: 40)).foregroundColor(.blue)
        }
    }
#endif
