// A Mac Catalyst test bundle has no host app, so UIKit can't create the windows these tests put an editor in.
#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import Foundation
    @testable import MarkdownUIEditor
    import XCTest

    #if os(macOS)
        import AppKit

        private typealias PlatformView = NSView
        private typealias PlatformImageView = NSImageView
        private typealias PlatformTextView = NSTextView
        private typealias PlatformTableGridView = AppKitMarkdownTableGridView
    #else
        import UIKit

        private typealias PlatformView = UIView
        private typealias PlatformImageView = UIImageView
        private typealias PlatformTextView = UITextView
        private typealias PlatformTableGridView = UIKitMarkdownTableGridView
    #endif

    /// Image views are 240×160 in body text and table cells, and shrink with the same 3:2 shape to fit a narrower line.
    @MainActor final class MarkdownImageViewSizeTests: XCTestCase {
        func testBodyImageViewIs240By160() throws {
            let editor = showEditor("Intro ![chart](chart.png) text", width: 600)
            let imageView = try XCTUnwrap(imageViews(in: editor).first)
            XCTAssertEqual(imageView.frame.size, CGSize(width: 240, height: 160))
        }

        func testBodyImageViewInANarrowEditorShrinksToTheLineAndKeeps3To2() throws {
            let editor = showEditor("Intro ![chart](chart.png) text", width: 120)
            let imageView = try XCTUnwrap(imageViews(in: editor).first)
            XCTAssertLessThan(imageView.frame.width, 120)
            assert3To2(imageView)
            assertContains(editor, imageView)
        }

        func testUnconstrainedColumnFitsTheImageViewAndTextBeforeIt() throws {
            let editor = showEditor("| a |\n| - |\n| See ![chart](chart.png) |", width: 600)
            let imageView = try XCTUnwrap(imageViews(in: editor).first)
            let cell = try XCTUnwrap(cell(containing: imageView))
            XCTAssertEqual(imageView.frame.size, CGSize(width: 240, height: 160))
            XCTAssertGreaterThanOrEqual(contentWidth(of: cell), 240)
            XCTAssertGreaterThan(cell.convert(imageView.bounds, from: imageView).minX, cell.bounds.width - contentWidth(of: cell), "The image stays on the line of the text before it")
            assertContains(cell, imageView)
        }

        func testConstrainedColumnShrinksTheImageViewInsideItsCellAndKeeps3To2() throws {
            for markdown in ["| a |\n| - |\n| ![chart](chart.png) |", "| a | b |\n| - | - |\n| ![chart](chart.png) | Some text that fills its column |"] {
                let editor = showEditor(markdown, width: 200)
                let imageView = try XCTUnwrap(imageViews(in: editor).first, markdown)
                let cell = try XCTUnwrap(cell(containing: imageView), markdown)
                XCTAssertLessThan(imageView.frame.width, 240, markdown)
                XCTAssertLessThanOrEqual(imageView.frame.width, contentWidth(of: cell), markdown)
                assert3To2(imageView, markdown)
                assertContains(cell, imageView, markdown)
            }
        }

        func testRowIsTallEnoughForTheImageView() throws {
            for width in [600.0, 200] {
                let editor = showEditor("| a | b |\n| - | - |\n| ![chart](chart.png) | b |", width: width)
                let imageView = try XCTUnwrap(imageViews(in: editor).first)
                let cell = try XCTUnwrap(cell(containing: imageView))
                let grid = try XCTUnwrap(subviews(of: PlatformTableGridView.self, in: editor).first)
                if width == 600 {
                    XCTAssertEqual(imageView.frame.size, CGSize(width: 240, height: 160))
                } else {
                    assert3To2(imageView, "width \(width)")
                }
                assertContains(cell, imageView, "width \(width)")
                assertContains(grid, imageView, "width \(width)")
            }
        }

        // MARK: - Helpers

        private func assert3To2(_ view: PlatformView, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertGreaterThan(view.frame.width, 0, message, file: file, line: line)
            XCTAssertEqual(view.frame.width * 2, view.frame.height * 3, accuracy: 0.5, "3:2 \(view.frame.size) \(message)", file: file, line: line)
        }

        private func assertContains(_ container: PlatformView, _ view: PlatformView, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
            let frame = container.convert(view.bounds, from: view)
            XCTAssertTrue(container.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) lies inside \(container.bounds) \(message)", file: file, line: line)
        }

        /// The image attachment views: the boxes holding each native image view.
        private func imageViews(in editor: MarkdownTextView) -> [PlatformView] {
            subviews(of: PlatformImageView.self, in: editor).compactMap(\.superview)
        }

        private func cell(containing view: PlatformView) -> PlatformTextView? {
            var ancestor = view.superview
            while let candidate = ancestor {
                if let cell = candidate as? PlatformTextView, !(cell is MarkdownTextView) {
                    return cell
                }
                ancestor = candidate.superview
            }
            return nil
        }

        private func subviews<View: PlatformView>(of type: View.Type, in rootView: PlatformView) -> [View] {
            ((rootView as? View).map { [$0] } ?? []) + rootView.subviews.flatMap { subviews(of: type, in: $0) }
        }

        #if os(macOS)
            private func showEditor(_ markdown: String, width: CGFloat) -> MarkdownTextView {
                let editor = MarkdownTextView(usingTextLayoutManager: true)
                editor.document = MarkdownDocument(markdown: markdown)
                editor.frame = NSRect(x: 0, y: 0, width: width, height: 600)
                let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = editor
                window.orderFront(nil)
                addTeardownBlock { @MainActor in window.orderOut(nil) }
                settle(editor)
                return editor
            }

            private func settle(_ editor: MarkdownTextView) {
                for _ in 0 ..< 3 {
                    if let manager = editor.textLayoutManager {
                        manager.ensureLayout(for: manager.documentRange)
                    }
                    editor.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                }
            }

            private func contentWidth(of cell: NSTextView) -> CGFloat {
                cell.bounds.width - 2 * cell.textContainerInset.width
            }
        #else
            private func showEditor(_ markdown: String, width: CGFloat) -> MarkdownTextView {
                let editor = MarkdownTextView(usingTextLayoutManager: true)
                editor.document = MarkdownDocument(markdown: markdown)
                editor.frame = CGRect(x: 0, y: 0, width: width, height: 600)
                let window = UIWindow(frame: editor.frame)
                window.rootViewController = UIViewController()
                window.rootViewController?.view.addSubview(editor)
                window.isHidden = false
                addTeardownBlock { @MainActor in window.isHidden = true }
                settle(editor)
                return editor
            }

            private func settle(_ editor: MarkdownTextView) {
                for _ in 0 ..< 3 {
                    if let manager = editor.textLayoutManager {
                        manager.ensureLayout(for: manager.documentRange)
                    }
                    editor.layoutIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                }
            }

            private func contentWidth(of cell: UITextView) -> CGFloat {
                cell.bounds.width - cell.textContainerInset.left - cell.textContainerInset.right
            }
        #endif
    }

#endif
