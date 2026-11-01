#if os(iOS) || targetEnvironment(macCatalyst)
    @testable import MarkdownUIEditor
    import UIKit
    import XCTest

    @MainActor final class MarkdownTextViewDynamicTypeTests: XCTestCase {
        private let markdown = "# Heading\n\nbody `code`\n\n| A |\n| - |\n| cell |"

        func testBuiltInThemesScaleBodyHeadingCodeAndTableCellFontsTogether() throws {
            let categories: [UIContentSizeCategory] = [.extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraLarge]
            for theme in [MarkdownEditorTheme.basic, .gitHub, .docC] {
                var bodySizes: [CGFloat] = []
                var headingRatios: [CGFloat] = []
                for category in categories {
                    let editor = makeTextView(category: category)
                    editor.editorTheme = theme
                    editor.document = MarkdownDocument(markdown: markdown)

                    let body = try font(of: "body", in: editor)
                    XCTAssertEqual(body.pointSize, bodySize(category), accuracy: 0.01, "\(category)")
                    XCTAssertEqual(try font(of: "code", in: editor).pointSize, body.pointSize, accuracy: 0.01, "\(category)")
                    XCTAssertEqual(try cellFont(in: editor).pointSize, body.pointSize, accuracy: 0.01, "\(category)")
                    bodySizes.append(body.pointSize)
                    headingRatios.append(try font(of: "Heading", in: editor).pointSize / body.pointSize)
                }
                XCTAssertEqual(bodySizes, bodySizes.sorted())
                XCTAssertEqual(Set(bodySizes).count, categories.count, "Every category renders at its own size")
                for ratio in headingRatios {
                    XCTAssertEqual(ratio, headingRatios[1], accuracy: 0.05, "Headings keep their size relative to body text")
                }
            }
        }

        func testCustomThemesScaleOnlyWhenTheyOptIn() throws {
            for adjusts in [false, true] {
                let theme = customTheme(adjustsFontForContentSizeCategory: adjusts)
                XCTAssertEqual(theme.adjustsFontForContentSizeCategory, adjusts)
                for category in [UIContentSizeCategory.large, .accessibilityExtraLarge] {
                    let editor = makeTextView(category: category)
                    editor.editorTheme = theme
                    editor.document = MarkdownDocument(markdown: markdown)
                    let expected = adjusts ? 20 * bodySize(category) / bodySize(.large) : 20

                    XCTAssertEqual(try font(of: "body", in: editor).pointSize, expected, accuracy: 0.5, "adjusts: \(adjusts), \(category)")
                    XCTAssertTrue(editor.editorTheme === theme, "The editor reports the theme it was given")
                }
            }

            let editor = makeTextView(category: .accessibilityExtraLarge)
            editor.editorTheme = customTheme(adjustsFontForContentSizeCategory: false)
            editor.document = MarkdownDocument(markdown: markdown)
            editor.editorTheme = customTheme(adjustsFontForContentSizeCategory: true)
            XCTAssertEqual(
                try font(of: "body", in: editor).pointSize, 20 * bodySize(.accessibilityExtraLarge) / bodySize(.large), accuracy: 0.01,
                "Opting in is a theme change even when the attributes are equal"
            )
        }

        func testDefaultThemeInitializerDoesNotScale() {
            XCTAssertFalse(customTheme().adjustsFontForContentSizeCategory)
            XCTAssertTrue(MarkdownEditorTheme.basic.adjustsFontForContentSizeCategory)
            XCTAssertTrue(MarkdownEditorTheme.gitHub.adjustsFontForContentSizeCategory)
            XCTAssertTrue(MarkdownEditorTheme.docC.adjustsFontForContentSizeCategory)
        }

        func testChangingTheTextSizeRendersAgainAndKeepsTheSelection() throws {
            let editor = makeTextView(category: .large)
            editor.document = MarkdownDocument(markdown: markdown)
            let document = editor.document
            XCTAssertTrue(editor.becomeFirstResponder())
            let selection = (editor.textStorage.string as NSString).range(of: "ody")
            editor.selectedRange = selection
            let largeBody = try font(of: "body", in: editor).pointSize
            let largeHeading = try font(of: "Heading", in: editor).pointSize
            let largeCell = try cellFont(in: editor).pointSize

            editor.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
            editor.updateTraitsIfNeeded()

            let body = try font(of: "body", in: editor).pointSize
            XCTAssertGreaterThan(body, largeBody)
            XCTAssertEqual(body, bodySize(.accessibilityExtraLarge), accuracy: 0.01)
            XCTAssertEqual(try font(of: "Heading", in: editor).pointSize / body, largeHeading / largeBody, accuracy: 0.01)
            XCTAssertEqual(try font(of: "code", in: editor).pointSize, body, accuracy: 0.01)
            XCTAssertEqual(try cellFont(in: editor).pointSize, body, accuracy: 0.01)
            XCTAssertGreaterThan(try cellFont(in: editor).pointSize, largeCell)
            XCTAssertEqual(editor.selectedRange, selection)
            XCTAssertEqual(editor.document, document)
            XCTAssertEqual(try XCTUnwrap(editor.typingAttributes[.font] as? UIFont).pointSize, body, accuracy: 0.01)
        }

        /// The system body text size at a content size category.
        private func bodySize(_ category: UIContentSizeCategory) -> CGFloat {
            UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).pointSize
        }

        private func customTheme(adjustsFontForContentSizeCategory: Bool? = nil) -> MarkdownEditorTheme {
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20)]
            let headings = Dictionary(uniqueKeysWithValues: MarkdownHeadingLevel.allCases.map { ($0, body) })
            guard let adjustsFontForContentSizeCategory else {
                return MarkdownEditorTheme(
                    bodyAttributes: body, headingAttributes: headings, codeAttributes: body,
                    sourceAttributes: body, linkAttributes: [:], objectPlaceholderAttributes: body
                )
            }
            return MarkdownEditorTheme(
                bodyAttributes: body, headingAttributes: headings, codeAttributes: body,
                sourceAttributes: body, linkAttributes: [:], objectPlaceholderAttributes: body,
                adjustsFontForContentSizeCategory: adjustsFontForContentSizeCategory
            )
        }

        private func makeTextView(category: UIContentSizeCategory) -> MarkdownTextView {
            let textView = MarkdownTextView(usingTextLayoutManager: true)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 358, height: 800))
            window.rootViewController = UIViewController()
            textView.frame = window.bounds
            textView.traitOverrides.preferredContentSizeCategory = category
            window.rootViewController?.view.addSubview(textView)
            window.makeKeyAndVisible()
            addTeardownBlock { @MainActor in window.isHidden = true }
            return textView
        }

        private func font(of text: String, in editor: MarkdownTextView) throws -> UIFont {
            let location = (editor.textStorage.string as NSString).range(of: text).location
            XCTAssertNotEqual(location, NSNotFound, text)
            return try XCTUnwrap(editor.textStorage.attribute(.font, at: location, effectiveRange: nil) as? UIFont)
        }

        private func cellFont(in editor: MarkdownTextView) throws -> UIFont {
            if let manager = editor.textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
            }
            editor.layoutIfNeeded()
            let cell = try XCTUnwrap(subviews(of: UITextView.self, in: editor).first { $0.accessibilityLabel == "Table row 1, column 1" })
            return try XCTUnwrap(cell.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        }

        private func subviews<View: UIView>(of type: View.Type, in rootView: UIView) -> [View] {
            let current = (rootView as? View).map { [$0] } ?? []
            return current + rootView.subviews.flatMap { self.subviews(of: type, in: $0) }
        }
    }
#endif
