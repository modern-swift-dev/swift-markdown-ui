#if os(macOS)
    import AppKit
    @testable import MarkdownUI
    import SwiftUI
    import XCTest

    @MainActor final class InlineImageLinkTests: XCTestCase {
        func testLoadedLinkedImageInRunningTextOpensItsLinkAndUnlinkedImageDoesNot() async throws {
            let opened = OpenedURLs()
            let hostingView = NSHostingView(rootView:
                MarkdownView("See [![badge](b.png)](https://ci.example/) and ![plain](p.png) status")
                    .markdownInlineImageProvider(SquareImageProvider())
                    .environment(\.openURL, OpenURLAction { url in
                        opened.urls.append(url)
                        return .handled
                    })
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            // SwiftUI creates its accessibility nodes lazily until assistive access is enabled.
            // The NSAccessibility protocol has no setter for this attribute, so the
            // informal protocol method is sent by selector, as assistive apps send it.
            _ = NSApplication.shared.perform(
                NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                with: NSNumber(value: true),
                with: "AXEnhancedUserInterface"
            )
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            hostingView.layoutSubtreeIfNeeded()

            // Before the images load, the alt text is a text link; wait for the 20-point images.
            for _ in 0 ..< 100 where hostingView.fittingSize.height < 20 {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertGreaterThanOrEqual(hostingView.fittingSize.height, 20)
            try await Task.sleep(for: .milliseconds(100))
            let badge = try XCTUnwrap(pressableElement(labeled: "badge", in: hostingView), "The loaded linked image is pressable")
            let frame = try XCTUnwrap((badge.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
            XCTAssertEqual(frame.size, CGSize(width: 20, height: 20), "The link covers the image")
            XCTAssertNil(pressableElement(labeled: "plain", in: hostingView), "Unlinked images are not tappable")

            XCTAssertTrue(press(badge))
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(opened.urls, [URL(string: "https://ci.example/")])
        }

        /// Returns a link or button element with the label that can be pressed.
        private func pressableElement(labeled label: String, in object: Any) -> NSObject? {
            guard let element = object as? NSObject else {
                return nil
            }
            let role = element.value(forKey: "accessibilityRole") as? NSAccessibility.Role
            if role == .link || role == .button,
               element.value(forKey: "accessibilityLabel") as? String == label,
               element.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                return element
            }
            if let view = element as? NSView {
                for child in view.subviews {
                    if let match = pressableElement(labeled: label, in: child) {
                        return match
                    }
                }
            }
            for child in (element.value(forKey: "accessibilityChildren") as? [Any]) ?? [] {
                if let match = pressableElement(labeled: label, in: child) {
                    return match
                }
            }
            return nil
        }

        private func press(_ element: NSObject) -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(element.method(for: selector), to: Press.self)(element, selector)
        }
    }

    @MainActor private final class OpenedURLs {
        var urls: [URL] = []
    }

    private struct SquareImageProvider: InlineImageProvider {
        func image(with url: URL, label: String) async throws -> Image {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return Image(try XCTUnwrap(context.makeImage()), scale: 1, label: Text(label))
        }
    }
#endif
