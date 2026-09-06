#if os(macOS) || os(iOS) || targetEnvironment(macCatalyst)
    @testable import MarkdownUIEditor
    import XCTest

    #if canImport(UIKit)
        import UIKit
    #else
        import AppKit
    #endif

    @MainActor final class MarkdownTaskCheckboxLayerTests: XCTestCase {
        func testMovingAndRecoloringCheckboxReusesShape() throws {
            let layer = MarkdownTaskCheckboxLayer()
            let theme = MarkdownEditorTheme.basic
            let black = CGColor(gray: 0, alpha: 1)
            let gray = CGColor(gray: 0.5, alpha: 1)
            let rect = CGRect(x: 70, y: 30, width: 1, height: 20)
            layer.update(textRect: rect, checked: true, color: black, theme: theme)
            let firstPath = try XCTUnwrap(layer.path)
            let firstFrame = layer.frame

            for offset in 1 ... 20 {
                layer.update(textRect: rect.offsetBy(dx: 0, dy: CGFloat(offset)), checked: true, color: gray, theme: theme)
                XCTAssertTrue(try XCTUnwrap(layer.path) === firstPath)
                XCTAssertEqual(layer.frame.minY, firstFrame.minY + CGFloat(offset))
                XCTAssertEqual(layer.strokeColor, gray)
            }
        }

        func testTogglingAndChangingFontSizeRebuildShape() throws {
            let layer = MarkdownTaskCheckboxLayer()
            let theme = MarkdownEditorTheme.basic
            let rect = CGRect(x: 70, y: 30, width: 1, height: 20)
            let color = CGColor(gray: 0, alpha: 1)
            layer.update(textRect: rect, checked: false, color: color, theme: theme)
            let uncheckedPath = try XCTUnwrap(layer.path)
            layer.update(textRect: rect, checked: true, color: color, theme: theme)
            let checkedPath = try XCTUnwrap(layer.path)
            XCTAssertNotEqual(checkedPath, uncheckedPath)

            #if canImport(UIKit)
                let font = UIFont.systemFont(ofSize: 40)
            #else
                let font = NSFont.systemFont(ofSize: 40)
            #endif
            let larger = MarkdownEditorTheme(
                bodyAttributes: [.font: font], headingAttributes: [:], codeAttributes: [:],
                sourceAttributes: [:], linkAttributes: [:], objectPlaceholderAttributes: [:]
            )
            let previousSize = layer.frame.size
            layer.update(textRect: rect, checked: true, color: color, theme: larger)
            XCTAssertNotEqual(try XCTUnwrap(layer.path), checkedPath)
            XCTAssertGreaterThan(layer.frame.width, previousSize.width)
            XCTAssertEqual(layer.frame.width, 48)
            XCTAssertEqual(layer.lineWidth, 4)
        }
    }
#endif
