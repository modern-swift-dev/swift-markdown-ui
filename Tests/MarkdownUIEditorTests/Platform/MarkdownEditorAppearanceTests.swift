#if os(macOS) || os(iOS) || targetEnvironment(macCatalyst)
    @testable import MarkdownUIEditor
    import XCTest

    #if canImport(UIKit)
        import UIKit
    #else
        import AppKit
    #endif

    /// Colors drawn into layers follow light and dark appearance switches.
    @MainActor final class MarkdownEditorAppearanceTests: XCTestCase {
        #if canImport(UIKit)
            func testTaskCheckboxesFollowAppearanceChanges() throws {
                let window = makeWindow(style: .light)
                let editor = MarkdownTextView(usingTextLayoutManager: true)
                editor.frame = window.bounds
                window.rootViewController?.view.addSubview(editor)
                editor.document = MarkdownDocument(markdown: "- [ ] task")
                editor.layoutIfNeeded()
                let checkbox = try XCTUnwrap(editor.layer.sublayers?.compactMap { $0 as? MarkdownTaskCheckboxLayer }.first)
                XCTAssertEqual(checkbox.strokeColor, resolved(.label, .light))

                // UIKit delivers trait changes before the next layout pass; this test runs no layout.
                window.overrideUserInterfaceStyle = .dark
                window.updateTraitsIfNeeded()
                XCTAssertEqual(checkbox.strokeColor, resolved(.label, .dark))
                window.overrideUserInterfaceStyle = .light
                window.updateTraitsIfNeeded()
                XCTAssertEqual(checkbox.strokeColor, resolved(.label, .light))
            }

            func testTableCellBordersFollowAppearanceChanges() throws {
                let window = makeWindow(style: .light)
                let grid = try makeGrid()
                window.rootViewController?.view.addSubview(grid)
                let cells = textViews(in: grid)
                XCTAssertEqual(cells.count, 4)
                XCTAssertNotEqual(resolved(.opaqueSeparator, .light), resolved(.opaqueSeparator, .dark))
                for cell in cells {
                    XCTAssertEqual(cell.layer.borderColor, resolved(.opaqueSeparator, .light))
                }

                window.overrideUserInterfaceStyle = .dark
                window.updateTraitsIfNeeded()
                for cell in cells {
                    XCTAssertEqual(cell.layer.borderColor, resolved(.opaqueSeparator, .dark))
                }
            }

            private func makeWindow(style: UIUserInterfaceStyle) -> UIWindow {
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
                window.overrideUserInterfaceStyle = style
                window.rootViewController = UIViewController()
                window.makeKeyAndVisible()
                addTeardownBlock { @MainActor in window.isHidden = true }
                return window
            }

            private func resolved(_ color: UIColor, _ style: UIUserInterfaceStyle) -> CGColor {
                color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).cgColor
            }

            private func textViews(in view: UIView) -> [UITextView] {
                ((view as? UITextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews(in:))
            }
        #else
            func testTaskCheckboxesFollowAppearanceChanges() throws {
                let window = makeWindow(appearance: .aqua)
                let editor = MarkdownTextView(usingTextLayoutManager: true)
                editor.frame = try XCTUnwrap(window.contentView).bounds
                window.contentView?.addSubview(editor)
                editor.document = MarkdownDocument(markdown: "- [ ] task")
                window.displayIfNeeded()
                let checkbox = try XCTUnwrap(editor.layer?.sublayers?.compactMap { $0 as? MarkdownTaskCheckboxLayer }.first)
                XCTAssertEqual(checkbox.strokeColor, resolved(.labelColor, .aqua))

                window.appearance = NSAppearance(named: .darkAqua)
                XCTAssertEqual(checkbox.strokeColor, resolved(.labelColor, .darkAqua))
                window.appearance = NSAppearance(named: .aqua)
                XCTAssertEqual(checkbox.strokeColor, resolved(.labelColor, .aqua))
            }

            func testTableCellBordersFollowAppearanceChanges() throws {
                let window = makeWindow(appearance: .aqua)
                let grid = try makeGrid()
                window.contentView?.addSubview(grid)
                let cells = textViews(in: grid)
                XCTAssertEqual(cells.count, 4)
                XCTAssertNotEqual(resolved(.gridColor, .aqua), resolved(.gridColor, .darkAqua))
                for cell in cells {
                    XCTAssertEqual(cell.layer?.borderColor, resolved(.gridColor, .aqua))
                }

                window.appearance = NSAppearance(named: .darkAqua)
                for cell in cells {
                    XCTAssertEqual(cell.layer?.borderColor, resolved(.gridColor, .darkAqua))
                }
            }

            private func makeWindow(appearance: NSAppearance.Name) -> NSWindow {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
                return window
            }

            private func resolved(_ color: NSColor, _ appearance: NSAppearance.Name) -> CGColor? {
                var cgColor: CGColor?
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    cgColor = color.cgColor
                }
                return cgColor
            }

            private func textViews(in view: NSView) -> [NSTextView] {
                ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews(in:))
            }
        #endif

        private func makeGrid() throws -> MarkdownPlatformView {
            let attachment = MarkdownTableAttachment(table: MarkdownTable(
                alignments: [.left, .left],
                header: MarkdownTableRow(cells: [MarkdownTableCell(content: [.text("A")]), MarkdownTableCell(content: [.text("B")])]),
                rows: [MarkdownTableRow(cells: [MarkdownTableCell(content: [.text("1")]), MarkdownTableCell(content: [.text("2")])])]
            ))
            let provider = try XCTUnwrap(attachment.viewProvider(
                for: nil,
                location: NSTextContentStorage().documentRange.location,
                textContainer: NSTextContainer(size: CGSize(width: 260, height: 1000))
            ))
            return try XCTUnwrap(provider.view)
        }
    }

    #if canImport(UIKit)
        private typealias MarkdownPlatformView = UIView
    #else
        private typealias MarkdownPlatformView = NSView
    #endif
#endif
