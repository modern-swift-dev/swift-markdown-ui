import Foundation
@testable import MarkdownUIEditor
import XCTest

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

@MainActor final class MarkdownEditingSessionTests: XCTestCase {
    func testInitialConfigurationInstallsOnePopulatedProjection() throws {
        let session = MarkdownEditingSession(document: MarkdownDocument())
        let document = MarkdownDocument(markdown: "initial")
        let theme = MarkdownEditorTheme.docC
        let provider = MarkdownURLSessionImageProvider()
        let url = try XCTUnwrap(URL(string: "https://example.com/"))
        session.synchronizeFromBinding(document: document, theme: theme, baseURL: url, imageProvider: provider)
        let bridge = FakeTextViewBridge()
        session.attach(to: bridge)

        XCTAssertEqual(bridge.replacementCount, 1)
        XCTAssertEqual(bridge.markdownTextStorage.string, "initial\n")
        XCTAssertTrue(session.configuredTheme === theme)
        XCTAssertEqual(session.baseURL, url)
        XCTAssertTrue(session.imageProvider === provider)
    }

    func testCombinedConfigurationUpdateRebuildsOnceAndClampsSelection() throws {
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "long original text"))
        let bridge = FakeTextViewBridge()
        session.attach(to: bridge)
        bridge.markdownSelectedRanges = [NSRange(location: 10, length: 4)]
        let count = bridge.replacementCount
        let theme = MarkdownEditorTheme.docC
        let provider = MarkdownURLSessionImageProvider()
        let url = try XCTUnwrap(URL(string: "https://example.com/"))

        session.synchronizeFromBinding(document: MarkdownDocument(markdown: "x"), theme: theme, baseURL: url, imageProvider: provider)

        XCTAssertEqual(bridge.replacementCount, count + 1)
        XCTAssertEqual(bridge.markdownTextStorage.string, "x\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 2, length: 0)])
        session.synchronizeFromBinding(document: nil, theme: .docC, baseURL: url, imageProvider: provider)
        XCTAssertEqual(bridge.replacementCount, count + 1, "Equivalent theme and identical provider must not rebuild")

        let replacementProvider = MarkdownURLSessionImageProvider()
        session.synchronizeFromBinding(document: nil, theme: theme, baseURL: url, imageProvider: replacementProvider)
        XCTAssertEqual(bridge.replacementCount, count + 2)
        XCTAssertTrue(session.imageProvider === replacementProvider)
    }

    func testConfigurationUpdatePreservesUnchangedDraftAndDelayedBindingEcho() {
        let draft = MarkdownDocument(blocks: [.paragraph([.text("text")]), .paragraph([])])
        let session = MarkdownEditingSession(document: draft)
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 5, length: 0)])
        session.attach(to: bridge)
        let count = bridge.replacementCount
        session.synchronizeFromBinding(document: nil, theme: .docC, baseURL: nil, imageProvider: nil)
        XCTAssertEqual(session.document, draft)
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 5, length: 0)])
        XCTAssertEqual(bridge.replacementCount, count + 1)

        session.perform(.convertBlock(.heading(.one)))
        let published = session.document
        session.perform(.convertBlock(.heading(.two)))
        let current = session.document
        let countAfterEdits = bridge.replacementCount
        session.synchronizeFromBinding(document: published, theme: .gitHub, baseURL: nil, imageProvider: nil)
        XCTAssertEqual(session.document, current, "A delayed echo must not overwrite the latest native edit")
        XCTAssertEqual(bridge.replacementCount, countAfterEdits + 1)
    }

    func testFocusingRichLeavesNeverRevealsMarkdownDelimiters() {
        let document = MarkdownDocument(blocks: [
            .paragraph([.strong([.text("bold")])]),
            .heading(level: .two, content: [.emphasis([.text("heading")])])
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 2, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        session.selectionDidChange()
        XCTAssertEqual(bridge.markdownTextStorage.string, "bold\nheading\n")

        bridge.markdownSelectedRanges = [NSRange(location: 8, length: 0)]
        session.selectionDidChange()
        XCTAssertEqual(bridge.markdownTextStorage.string, "bold\nheading\n")
    }

    func testRichTypingReconcilesOnlyAffectedLeafAndKeepsAttachmentIdentity() throws {
        let document = MarkdownDocument(blocks: [
            .paragraph([.strong([.text("bold")])]),
            .paragraph([.image(source: "image.png", title: nil, children: [.text("alt")])]),
            .paragraph([.text("after 👩‍👩‍👧‍👦")])
        ])
        let activePath = EditorNodePath([.block(0)])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 2, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)
        session.selectionDidChange()
        let originalAttachment = try XCTUnwrap(
            attachment(in: session.projection.attributedString, ofType: MarkdownImageAttachment.self)
        )
        let activeUnit = try XCTUnwrap(session.projection.index.unit(at: activePath))
        XCTAssertTrue(try XCTUnwrap(bridge.markdownTypingAttributes[.markdownEditorStrong] as? Bool))

        let insertion = NSAttributedString(string: "er", attributes: bridge.markdownTypingAttributes)
        XCTAssertTrue(session.shouldReplaceCharacters(in: NSRange(location: 2, length: 0), with: "er"))
        bridge.replaceAttributedCharacters(
            in: NSRange(location: 2, length: 0),
            with: insertion
        )
        bridge.markdownSelectedRanges = [NSRange(location: 4, length: 0)]
        session.storageDidChange()

        XCTAssertEqual(
            session.document.blocks[0],
            .paragraph([.strong([.text("boerld")])])
        )
        XCTAssertEqual(activeUnit.projectionRange.location, 0)
        XCTAssertEqual(bridge.markdownTextStorage.string, "boerld\n\u{fffc}\nafter 👩‍👩‍👧‍👦\n")
        XCTAssertTrue(session.projection.attributedString === bridge.markdownTextStorage)
        XCTAssertTrue(
            originalAttachment === attachment(
                in: session.projection.attributedString,
                ofType: MarkdownImageAttachment.self
            )
        )
        XCTAssertEqual(session.projection.index.projectionUTF16Length, bridge.markdownTextStorage.length)
    }

    func testCollapsedInlineCommandStylesSubsequentTypingWithoutMarkers() {
        let cases: [(MarkdownInlineStyle, MarkdownInline)] = [
            (.strong, .strong([.text("x")])),
            (.emphasis, .emphasis([.text("x")])),
            (.strikethrough, .strikethrough([.text("x")])),
            (.code, .code("x"))
        ]

        for (style, expected) in cases {
            let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 0)])
            let session = MarkdownEditingSession(document: MarkdownDocument(blocks: [.paragraph([])]))
            session.attach(to: bridge)
            session.selectionDidChange()
            session.perform(.toggleInline(style))

            XCTAssertTrue(session.shouldReplaceCharacters(in: NSRange(location: 0, length: 0), with: "x"))
            bridge.replaceAttributedCharacters(
                in: NSRange(location: 0, length: 0),
                with: NSAttributedString(string: "x", attributes: bridge.markdownTypingAttributes)
            )
            bridge.markdownSelectedRanges = [NSRange(location: 1, length: 0)]
            session.storageDidChange()

            XCTAssertEqual(session.document.blocks, [.paragraph([expected])])
            XCTAssertEqual(bridge.markdownTextStorage.string, "x\n")
        }
    }

    func testCollapsedLinkCommandAppliesDestinationToSubsequentTyping() {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 0)])
        let session = MarkdownEditingSession(document: MarkdownDocument(blocks: [.paragraph([])]))
        session.attach(to: bridge)
        session.selectionDidChange()
        session.perform(.setLink(destination: "/target", title: "Title"))

        XCTAssertTrue(session.shouldReplaceCharacters(in: NSRange(location: 0, length: 0), with: "link"))
        bridge.replaceAttributedCharacters(
            in: NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "link", attributes: bridge.markdownTypingAttributes)
        )
        bridge.markdownSelectedRanges = [NSRange(location: 4, length: 0)]
        session.storageDidChange()

        XCTAssertEqual(session.document.blocks, [
            .paragraph([.link(destination: "/target", title: "Title", children: [.text("link")])])
        ])
        XCTAssertEqual(bridge.markdownTextStorage.string, "link\n")
    }

    func testLinkCommandsAtCollapsedCaretEditTheSurroundingLink() {
        let original = MarkdownDocument(markdown: "a [*link*](/old) b")
        let bridge = FakeTextViewBridge()
        let session = MarkdownEditingSession(document: original)
        session.attach(to: bridge)
        XCTAssertEqual(bridge.markdownTextStorage.string, "a link b\n")

        bridge.markdownSelectedRanges = [NSRange(location: 1, length: 0)]
        session.selectionDidChange()
        XCTAssertFalse(session.canPerform(.removeLink))

        bridge.markdownSelectedRanges = [NSRange(location: 4, length: 0)]
        session.selectionDidChange()
        XCTAssertTrue(session.canPerform(.removeLink))
        XCTAssertTrue(session.isActive(.removeLink))

        session.perform(.setLink(destination: "/new", title: "Title"))
        let relinked = MarkdownDocument(markdown: "a [*link*](/new \"Title\") b")
        XCTAssertEqual(session.document, relinked)
        XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown), relinked)
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 4, length: 0)])

        session.perform(.removeLink)
        let unlinked = MarkdownDocument(markdown: "a *link* b")
        XCTAssertEqual(session.document, unlinked)
        XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown), unlinked)
        session.selectionDidChange()
        XCTAssertFalse(session.canPerform(.removeLink))

        bridge.undoManager?.undo()
        XCTAssertEqual(session.document, original)
    }

    func testLinkAtSelectionReportsTheSurroundingLinksDestinationAndTitle() {
        let bridge = FakeTextViewBridge()
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: #"a [link](/old "Old title") b"#))
        session.attach(to: bridge)

        bridge.markdownSelectedRanges = [NSRange(location: 1, length: 0)]
        session.selectionDidChange()
        XCTAssertNil(session.linkAtSelection)

        bridge.markdownSelectedRanges = [NSRange(location: 4, length: 0)]
        session.selectionDidChange()
        XCTAssertEqual(session.linkAtSelection, MarkdownEditorLink(destination: "/old", title: "Old title"))
    }

    func testLinkDialogValuesReplaceTheTitleOrRemoveItWhenEmpty() {
        let bridge = FakeTextViewBridge()
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: #"a [link](/old "Old title") b"#))
        session.attach(to: bridge)
        bridge.markdownSelectedRanges = [NSRange(location: 4, length: 0)]
        session.selectionDidChange()

        session.perform(MarkdownEditorLink(destination: "/new", title: #"Say "hi""#).command)
        XCTAssertEqual(session.document.blocks, [.paragraph([
            .text("a "), .link(destination: "/new", title: #"Say "hi""#, children: [.text("link")]), .text(" b")
        ])])
        XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown), session.document, "The title's quotes are escaped")

        session.selectionDidChange()
        session.perform(MarkdownEditorLink(destination: "/new", title: "").command)
        XCTAssertEqual(session.document, MarkdownDocument(markdown: "a [link](/new) b"))
    }

    func testTextTypedAfterLinkOrInlineHTMLIsPlainButKeepsInlineStyles() {
        let cases: [(source: String, typed: String, expected: String)] = [
            ("[link](/u)", "x", "[link](/u)x"),
            // Native runs decode with the link outermost.
            ("**[link](/u)**", "x", "[**link**](/u)**x**"),
            ("<span>x</span>", " 2*3*4", "<span>x</span> 2\\*3\\*4")
        ]
        for (source, typed, expected) in cases {
            let bridge = FakeTextViewBridge()
            let session = MarkdownEditingSession(document: MarkdownDocument(markdown: source))
            session.attach(to: bridge)
            let end = bridge.markdownTextStorage.length - 1
            bridge.markdownSelectedRanges = [NSRange(location: end, length: 0)]
            session.selectionDidChange()
            XCTAssertFalse(session.canPerform(.removeLink), source)

            XCTAssertTrue(session.shouldReplaceCharacters(in: NSRange(location: end, length: 0), with: typed), source)
            bridge.replaceAttributedCharacters(
                in: NSRange(location: end, length: 0),
                with: NSAttributedString(string: typed, attributes: bridge.markdownTypingAttributes)
            )
            bridge.markdownSelectedRanges = [NSRange(location: end + typed.utf16.count, length: 0)]
            session.storageDidChange()

            XCTAssertEqual(session.document, MarkdownDocument(markdown: expected), source)
            XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown), session.document, source)
        }
    }

    func testReturnAfterHardLineBreakDoesNotLeaveTrailingBreak() {
        let bridge = FakeTextViewBridge()
        let session = MarkdownEditingSession(document: MarkdownDocument(blocks: [.paragraph([.text("a"), .lineBreak])]))
        session.attach(to: bridge)
        XCTAssertEqual(bridge.markdownTextStorage.string, "a\n\n")
        bridge.markdownSelectedRanges = [NSRange(location: 2, length: 0)]

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 2, length: 0), with: "\n"))

        XCTAssertEqual(session.document.blocks, [.paragraph([.text("a")]), .paragraph([])])
        XCTAssertFalse(session.document.markdown.contains("\\"))
        XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown).blocks.first, .paragraph([.text("a")]))
    }

    func testReturnSplitsHeadingIntoHeadingAndParagraph() {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 3, length: 0)])
        let session = MarkdownEditingSession(
            document: MarkdownDocument(blocks: [
                .heading(level: .two, content: [.strong([.text("abcdef")])])
            ])
        )
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 3, length: 0), with: "\n"))
        XCTAssertEqual(session.document.blocks, [
            .heading(level: .two, content: [.strong([.text("abc")])]),
            .paragraph([.strong([.text("def")])])
        ])
        XCTAssertEqual(bridge.markdownTextStorage.string, "abc\ndef\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 4, length: 0)])
    }

    func testReturnSplitsListItemAndPreservesTaskSemantics() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(
                    taskState: .checked,
                    blocks: [.paragraph([.text("task")])]
                )]
            ))
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 2, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 2, length: 0), with: "\n"))
        guard case let .list(list) = session.document.blocks.first else {
            return XCTFail("Expected a list")
        }
        XCTAssertEqual(list.items.map(\.taskState), [.checked, .unchecked])
        XCTAssertEqual(list.items.map(\.blocks), [
            [.paragraph([.text("ta")])],
            [.paragraph([.text("sk")])]
        ])
        XCTAssertEqual(bridge.markdownTextStorage.string, "ta\nsk\n")
    }

    func testReturnAtStartOfCheckedTaskKeepsCheckWithText() {
        let original = MarkdownDocument(markdown: "- [x] done")
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 0)])
        let session = MarkdownEditingSession(document: original)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 0, length: 0), with: "\n"))

        let expected = MarkdownDocument(blocks: [.list(MarkdownList(kind: .unordered, isTight: true, items: [
            MarkdownListItem(taskState: .unchecked, blocks: [.paragraph([])]),
            MarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("done")])])
        ]))])
        XCTAssertEqual(session.document, expected)
        XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown), expected)
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 1, length: 0)])

        bridge.undoManager?.undo()
        XCTAssertEqual(session.document, original)
    }

    func testIndentingInOrderedListStartingAtFiveStartsNestedListAtOne() {
        let original = MarkdownDocument(markdown: "5. A\n6. B\n7. C")
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 2, length: 0)])
        let session = MarkdownEditingSession(document: original)
        session.attach(to: bridge)

        session.perform(.indent)
        let expected = MarkdownDocument(markdown: "5. A\n   1. B\n6. C")
        XCTAssertEqual(session.document, expected)
        XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown), expected)

        bridge.undoManager?.undo()
        XCTAssertEqual(session.document, original)

        bridge.undoManager?.redo()
        bridge.markdownSelectedRanges = [NSRange(location: 4, length: 0)]
        session.perform(.indent)
        XCTAssertEqual(session.document, MarkdownDocument(markdown: "5. A\n   1. B\n   2. C"))
    }

    func testReturnAtEndCreatesNewUnorderedListItem() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("item")])])]
            ))
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 4, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 4, length: 0), with: "\n"))
        XCTAssertEqual(session.document.blocks, [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("item")])]),
                    MarkdownListItem(blocks: [.paragraph([])])
                ]
            ))
        ])
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 5, length: 0)])
    }

    func testReturnAtDocumentEndCreatesNewUnorderedListItem() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("item")])])]
            ))
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 5, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 5, length: 0), with: "\n"))
        XCTAssertEqual(session.document.blocks, [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("item")])]),
                    MarkdownListItem(blocks: [.paragraph([])])
                ]
            ))
        ])
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 5, length: 0)])
    }

    func testReturnAtBoundaryBeforeAnotherListCreatesItemInPrecedingList() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .ordered(start: 1),
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("Draft")])]),
                    MarkdownListItem(blocks: [.paragraph([.text("Review")])])
                ]
            )),
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("Build")])])]
            ))
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 13, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 13, length: 0), with: "\n"))
        XCTAssertEqual(session.document.blocks, [
            .list(MarkdownList(
                kind: .ordered(start: 1),
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("Draft")])]),
                    MarkdownListItem(blocks: [.paragraph([.text("Review")])]),
                    MarkdownListItem(blocks: [.paragraph([])])
                ]
            )),
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("Build")])])]
            ))
        ])
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 13, length: 0)])
    }

    func testReturnAtEndCreatesNewOrderedListItemAndPreservesStart() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .ordered(start: 4),
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("item")])])]
            ))
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 4, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 4, length: 0), with: "\n"))
        XCTAssertEqual(session.document.blocks, [
            .list(MarkdownList(
                kind: .ordered(start: 4),
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("item")])]),
                    MarkdownListItem(blocks: [.paragraph([])])
                ]
            ))
        ])
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 5, length: 0)])
    }

    func testReturnOnNewEmptyListItemExitsList() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("item")])])]
            ))
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 4, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 4, length: 0), with: "\n"))
        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 5, length: 0), with: "\n"))
        XCTAssertEqual(session.document.blocks, [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("item")])])]
            )),
            .paragraph([])
        ])
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 5, length: 0)])
    }

    func testReturnOnEmptyMiddleListItemSplitsListAroundParagraph() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("Build")])]),
                    MarkdownListItem(blocks: [.paragraph([])]),
                    MarkdownListItem(blocks: [.paragraph([.text("Run")])])
                ]
            ))
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 6, length: 0)])
        var publishedDocument: MarkdownDocument?
        let session = MarkdownEditingSession(document: document) { publishedDocument = $0 }
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 6, length: 0), with: "\n"))

        let expected = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("Build")])])]
            )),
            .paragraph([]),
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("Run")])])]
            ))
        ])
        XCTAssertEqual(session.document, expected)
        XCTAssertEqual(bridge.markdownTextStorage.string, "Build\n\nRun\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 6, length: 0)])

        guard let listExit = publishedDocument else {
            return XCTFail("Expected the list exit to publish a document")
        }
        session.replaceDocumentFromBinding(MarkdownDocument(markdown: listExit.markdown))
        XCTAssertEqual(session.document, expected)
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 6, length: 0)])

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 6, length: 0), with: "\n"))
        let expectedAfterAnotherReturn = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("Build")])])]
            )),
            .paragraph([]),
            .paragraph([]),
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("Run")])])]
            ))
        ])
        XCTAssertEqual(session.document, expectedAfterAnotherReturn)
        XCTAssertEqual(bridge.markdownTextStorage.string, "Build\n\n\nRun\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 7, length: 0)])

        guard let secondParagraph = publishedDocument else {
            return XCTFail("Expected the additional paragraph to publish a document")
        }
        session.replaceDocumentFromBinding(MarkdownDocument(markdown: secondParagraph.markdown))
        XCTAssertEqual(session.document, expectedAfterAnotherReturn)
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 7, length: 0)])
    }

    func testReturnOnEmptyMiddleNestedItemOutdentsWithoutReordering() {
        func nested(_ items: [MarkdownListItem]) -> MarkdownBlock {
            .list(MarkdownList(kind: .unordered, isTight: true, items: items))
        }
        let document = MarkdownDocument(blocks: [nested([
            MarkdownListItem(blocks: [.paragraph([.text("A")]), nested([
                MarkdownListItem(blocks: [.paragraph([.text("B")])]),
                MarkdownListItem(blocks: [.paragraph([])]),
                MarkdownListItem(blocks: [.paragraph([.text("C")])])
            ])])
        ])])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 4, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 4, length: 0), with: "\n"))

        XCTAssertEqual(session.document, MarkdownDocument(blocks: [nested([
            MarkdownListItem(blocks: [.paragraph([.text("A")]), nested([MarkdownListItem(blocks: [.paragraph([.text("B")])])])]),
            MarkdownListItem(blocks: [.paragraph([]), nested([MarkdownListItem(blocks: [.paragraph([.text("C")])])])])
        ])]))
        XCTAssertEqual(bridge.markdownTextStorage.string, "A\nB\n\nC\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 4, length: 0)])

        bridge.undoManager?.undo()
        XCTAssertEqual(session.document, document)
    }

    func testReturnOnNewEmptyMiddleTaskItemSplitsChecklistAroundParagraph() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [
                    MarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("Write")])]),
                    MarkdownListItem(taskState: .unchecked, blocks: [.paragraph([.text("Review")])]),
                    MarkdownListItem(taskState: .unchecked, blocks: [.paragraph([.text("Ship")])])
                ]
            ))
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 5, length: 0)])
        var publishedDocuments: [MarkdownDocument] = []
        let session = MarkdownEditingSession(document: document) { publishedDocuments.append($0) }
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 5, length: 0), with: "\n"))
        guard let itemCreation = publishedDocuments.last else {
            return XCTFail("Expected the new task item to publish a document")
        }
        session.replaceDocumentFromBinding(MarkdownDocument(markdown: itemCreation.markdown))
        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 6, length: 0), with: "\n"))

        let expected = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("Write")])])]
            )),
            .paragraph([]),
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [
                    MarkdownListItem(taskState: .unchecked, blocks: [.paragraph([.text("Review")])]),
                    MarkdownListItem(taskState: .unchecked, blocks: [.paragraph([.text("Ship")])])
                ]
            ))
        ])
        XCTAssertEqual(session.document, expected)
        XCTAssertEqual(bridge.markdownTextStorage.string, "Write\n\nReview\nShip\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 6, length: 0)])

        guard let listExit = publishedDocuments.last else {
            return XCTFail("Expected the task list exit to publish a document")
        }
        session.replaceDocumentFromBinding(MarkdownDocument(markdown: listExit.markdown))
        XCTAssertEqual(session.document, expected)
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 6, length: 0)])
    }

    func testMarkdownBindingEchoPreservesEmptyParagraphWhenExitingListBeforeAnotherList() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .ordered(start: 1),
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("Draft")])]),
                    MarkdownListItem(blocks: [.paragraph([.text("Review")])]),
                    MarkdownListItem(blocks: [.paragraph([])])
                ]
            )),
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.text("Build")])])]
            ))
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 13, length: 0)])
        var publishedDocument: MarkdownDocument?
        let session = MarkdownEditingSession(document: document) { publishedDocument = $0 }
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 13, length: 0), with: "\n"))
        guard let publishedDocument else {
            return XCTFail("Expected the list exit to publish a document")
        }
        let bindingEcho = MarkdownDocument(markdown: publishedDocument.markdown)
        XCTAssertNotEqual(bindingEcho, publishedDocument)
        let replacementCount = bridge.replacementCount

        session.replaceDocumentFromBinding(bindingEcho)

        XCTAssertEqual(session.document, publishedDocument)
        XCTAssertEqual(bridge.replacementCount, replacementCount)
        XCTAssertEqual(bridge.markdownTextStorage.string, "Draft\nReview\n\nBuild\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 13, length: 0)])
    }

    func testReturnSplitsBlockquoteChildWithoutExposingPrefix() {
        let document = MarkdownDocument(blocks: [
            .blockquote([.paragraph([.emphasis([.text("quote")])])])
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 2, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 2, length: 0), with: "\n"))
        XCTAssertEqual(session.document.blocks, [
            .blockquote([
                .paragraph([.emphasis([.text("qu")])]),
                .paragraph([.emphasis([.text("ote")])])
            ])
        ])
        XCTAssertEqual(bridge.markdownTextStorage.string, "qu\note\n")
    }

    func testHardLineBreakSplitsParagraphLineInOneUndoStep() {
        let document = MarkdownDocument(markdown: "ab**cd**ef")
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 3, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)
        session.selectionDidChange()

        XCTAssertTrue(session.insertHardLineBreak())

        XCTAssertEqual(session.document.blocks, [
            .paragraph([.text("ab"), .strong([.text("c")]), .lineBreak, .strong([.text("d")]), .text("ef")])
        ])
        XCTAssertEqual(session.document.markdown, "ab**c**\\\n**d**ef\n")
        XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown), session.document)
        XCTAssertEqual(bridge.markdownTextStorage.string, "abc\ndef\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 4, length: 0)])

        bridge.undoManager?.undo()
        XCTAssertEqual(session.document, document)
        XCTAssertEqual(bridge.markdownTextStorage.string, "abcdef\n")
    }

    func testHardLineBreakReplacesSelectionAndIsUnavailableOutsideParagraphs() {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 1, length: 2)])
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "abcd\n\n# Title\n\n```\ncode\n```"))
        session.attach(to: bridge)

        XCTAssertTrue(session.insertHardLineBreak())
        XCTAssertEqual(session.document.blocks.first, .paragraph([.text("a"), .lineBreak, .text("d")]))

        let afterParagraph = session.document
        for text in ["Title", "code"] {
            let location = (bridge.markdownTextStorage.string as NSString).range(of: text).location
            bridge.markdownSelectedRanges = [NSRange(location: location + 1, length: 0)]
            XCTAssertFalse(session.insertHardLineBreak(), text)
            XCTAssertEqual(session.document, afterParagraph, text)
        }
    }

    func testEditorShortcutsRequireOuterFocusWithoutTableCellOrComposition() throws {
        let bridge = FakeTextViewBridge()
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "- item\n\n| Name |\n| --- |\n| Editor |"))
        session.attach(to: bridge)
        XCTAssertFalse(session.acceptsEditorShortcuts)
        XCTAssertTrue(session.selectionIsInListItem)

        bridge.markdownIsFirstResponder = true
        XCTAssertTrue(session.acceptsEditorShortcuts)

        bridge.markdownHasMarkedText = true
        XCTAssertFalse(session.acceptsEditorShortcuts)
        XCTAssertFalse(session.insertHardLineBreak())
        bridge.markdownHasMarkedText = false

        let tableAttachment = try XCTUnwrap(
            attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self)
        )
        tableAttachment.controller.updateSelection(
            at: MarkdownTableCellPosition(section: .body(row: 0), column: 0),
            range: NSRange(location: 2, length: 0)
        )
        XCTAssertFalse(session.acceptsEditorShortcuts)
        XCTAssertFalse(session.insertHardLineBreak())
    }

    func testMarkdownShortcutsConvertTheParagraphAndUndoRestoresTheTypedText() {
        func list(_ kind: MarkdownListKind, _ taskState: MarkdownTaskState? = nil) -> MarkdownBlock {
            .list(MarkdownList(kind: kind, isTight: true, items: [
                MarkdownListItem(taskState: taskState, blocks: [.paragraph([.text("rest")])])
            ]))
        }
        let cases: [(marker: String, typed: String, expected: MarkdownBlock)] = [
            ("#", " ", .heading(level: .one, content: [.text("rest")])),
            ("######", " ", .heading(level: .six, content: [.text("rest")])),
            ("-", " ", list(.unordered)),
            ("*", " ", list(.unordered)),
            ("+", " ", list(.unordered)),
            ("7.", " ", list(.ordered(start: 7))),
            ("3)", " ", list(.ordered(start: 3))),
            ("[ ]", " ", list(.unordered, .unchecked)),
            ("[x]", " ", list(.unordered, .checked)),
            (">", " ", .blockquote([.paragraph([.text("rest")])])),
            ("```swift", "\n", .codeBlock(info: "swift", content: "rest")),
            ("```", "\n", .codeBlock(info: nil, content: "rest"))
        ]
        for (marker, typed, expected) in cases {
            let caret = marker.utf16.count
            let original = MarkdownDocument(blocks: [.paragraph([.text("before")]), .paragraph([.text(marker + "rest")])])
            let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 7 + caret, length: 0)])
            let session = MarkdownEditingSession(document: original)
            session.convertsMarkdownShortcuts = true
            session.attach(to: bridge)

            XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 7 + caret, length: 0), with: typed), marker)

            XCTAssertEqual(session.document.blocks, [.paragraph([.text("before")]), expected], marker)
            XCTAssertEqual(bridge.markdownTextStorage.string, MarkdownProjectionBuilder().build(document: session.document).string, marker)
            XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 7, length: 0)], marker)

            bridge.undoManager?.undo()
            let literal = typed == "\n" ? marker + "rest" : marker + typed + "rest"
            XCTAssertEqual(session.document.blocks, [.paragraph([.text("before")]), .paragraph([.text(literal)])], marker)
            XCTAssertEqual(bridge.markdownTextStorage.string, "before\n\(literal)\n", marker)
            let literalCaret = 7 + caret + (typed == "\n" ? 0 : 1)
            XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: literalCaret, length: 0)], marker)
        }
    }

    func testMarkdownShortcutsConvertOnlyAPlainMarkerAtTheStartOfAParagraph() {
        let cases: [(document: MarkdownDocument, caret: Int, typed: String)] = [
            (MarkdownDocument(blocks: [.paragraph([.text("a#")])]), 2, " "),
            (MarkdownDocument(blocks: [.paragraph([.text("#######")])]), 7, " "),
            (MarkdownDocument(blocks: [.paragraph([.strong([.text("#")])])]), 1, " "),
            (MarkdownDocument(blocks: [.paragraph([.code("-")])]), 1, " "),
            (MarkdownDocument(blocks: [.heading(level: .one, content: [.text("#")])]), 1, " "),
            (MarkdownDocument(blocks: [.codeBlock(info: nil, content: "#")]), 1, " "),
            (MarkdownDocument(blocks: [.codeBlock(info: nil, content: "```swift")]), 8, "\n"),
            (MarkdownDocument(markdown: "- \\-"), 1, " "),
            (MarkdownDocument(markdown: "- 1\\."), 2, " "),
            (MarkdownDocument(markdown: "- [ ] \\[x]"), 3, " ")
        ]
        for (document, caret, typed) in cases {
            let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: caret, length: 0)])
            let session = MarkdownEditingSession(document: document)
            session.convertsMarkdownShortcuts = true
            session.attach(to: bridge)

            _ = session.shouldReplaceCharacters(in: NSRange(location: caret, length: 0), with: typed)

            XCTAssertEqual(session.document, document, document.markdown)
            XCTAssertFalse(bridge.undoManager?.canUndo ?? true, document.markdown)
        }
    }

    func testPastingAfterAMarkerDoesNotConvertTheParagraph() {
        let document = MarkdownDocument(blocks: [.paragraph([.text("#")])])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 1, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.convertsMarkdownShortcuts = true
        session.attach(to: bridge)

        XCTAssertTrue(session.paste(MarkdownClipboardPayload(plainText: " ")))

        XCTAssertEqual(session.document.blocks, [.paragraph([.text("# ")])])
        XCTAssertFalse(session.isPasting)
    }

    func testTaskMarkerTurnsAnOrdinaryListItemIntoATask() {
        let document = MarkdownDocument(markdown: "- first\n- [x]rest")
        let caret = 9
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: caret, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.convertsMarkdownShortcuts = true
        session.attach(to: bridge)
        XCTAssertEqual(bridge.markdownTextStorage.string, "first\n[x]rest\n")

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: caret, length: 0), with: " "))

        XCTAssertEqual(session.document.blocks, [.list(MarkdownList(kind: .unordered, isTight: true, items: [
            MarkdownListItem(blocks: [.paragraph([.text("first")])]),
            MarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("rest")])])
        ]))])
        bridge.undoManager?.undo()
        XCTAssertEqual(session.document.blocks, [.list(MarkdownList(kind: .unordered, isTight: true, items: [
            MarkdownListItem(blocks: [.paragraph([.text("first")])]),
            MarkdownListItem(blocks: [.paragraph([.text("[x] rest")])])
        ]))])
    }

    func testQuoteMarkerInsideAQuoteNestsAQuoteInsteadOfRemovingIt() {
        let document = MarkdownDocument(blocks: [.blockquote([.paragraph([.text("a")]), .paragraph([.text(">rest")])])])
        let caret = 3
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: caret, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.convertsMarkdownShortcuts = true
        session.attach(to: bridge)
        XCTAssertEqual(bridge.markdownTextStorage.string, "a\n>rest\n")

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: caret, length: 0), with: " "))

        XCTAssertEqual(session.document.blocks, [.blockquote([
            .paragraph([.text("a")]),
            .blockquote([.paragraph([.text("rest")])])
        ])])
        bridge.undoManager?.undo()
        XCTAssertEqual(session.document.blocks, [.blockquote([.paragraph([.text("a")]), .paragraph([.text("> rest")])])])
    }

    func testMarkdownShortcutsAreOffByDefaultAndWaitForComposition() {
        let document = MarkdownDocument(blocks: [.paragraph([.text("#")])])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 1, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)
        XCTAssertFalse(session.convertsMarkdownShortcuts)
        XCTAssertTrue(session.shouldReplaceCharacters(in: NSRange(location: 1, length: 0), with: " "))
        XCTAssertEqual(session.document, document)

        session.convertsMarkdownShortcuts = true
        bridge.markdownHasMarkedText = true
        XCTAssertTrue(session.shouldReplaceCharacters(in: NSRange(location: 1, length: 0), with: " "))
        XCTAssertEqual(session.document, document)

        bridge.markdownHasMarkedText = false
        session.compositionDidEnd()
        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 1, length: 0), with: " "))
        XCTAssertEqual(session.document.blocks, [.heading(level: .one, content: [])])
    }

    func testBackwardDeletionJoinsAdjacentParagraphs() {
        let document = MarkdownDocument(blocks: [
            .paragraph([.strong([.text("one")])]),
            .paragraph([.emphasis([.text("two")])])
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 4, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 3, length: 1), with: ""))
        XCTAssertEqual(session.document.blocks, [
            .paragraph([.strong([.text("one")]), .emphasis([.text("two")])])
        ])
        XCTAssertEqual(bridge.markdownTextStorage.string, "onetwo\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 3, length: 0)])
    }

    func testBackwardDeletionJoinsParagraphIntoPrecedingListItem() {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [.paragraph([.strong([.text("item")])])])]
            )),
            .paragraph([.emphasis([.text("after")])])
        ])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 5, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)

        XCTAssertFalse(session.shouldReplaceCharacters(in: NSRange(location: 4, length: 1), with: ""))
        XCTAssertEqual(session.document.blocks, [
            .list(MarkdownList(
                kind: .unordered,
                isTight: true,
                items: [MarkdownListItem(blocks: [
                    .paragraph([.strong([.text("item")]), .emphasis([.text("after")])])
                ])]
            ))
        ])
        XCTAssertEqual(bridge.markdownTextStorage.string, "itemafter\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 4, length: 0)])
    }

    func testMultipleRichEditsReconcileEachAffectedLeaf() {
        let bridge = FakeTextViewBridge(selectedRanges: [
            NSRange(location: 1, length: 0),
            NSRange(location: 5, length: 0)
        ])
        let session = MarkdownEditingSession(document: MarkdownDocument(blocks: [
            .paragraph([.strong([.text("one")])]),
            .paragraph([.emphasis([.text("two")])])
        ]))
        session.attach(to: bridge)

        XCTAssertTrue(session.shouldReplaceCharacters(
            in: [NSRange(location: 1, length: 0), NSRange(location: 5, length: 0)],
            with: ["X", "Y"]
        ))
        let secondAttributes = bridge.markdownTextStorage.attributes(at: 5, effectiveRange: nil)
        let firstAttributes = bridge.markdownTextStorage.attributes(at: 1, effectiveRange: nil)
        bridge.replaceAttributedCharacters(
            in: NSRange(location: 5, length: 0),
            with: NSAttributedString(string: "Y", attributes: secondAttributes)
        )
        bridge.replaceAttributedCharacters(
            in: NSRange(location: 1, length: 0),
            with: NSAttributedString(string: "X", attributes: firstAttributes)
        )
        bridge.markdownSelectedRanges = [
            NSRange(location: 2, length: 0),
            NSRange(location: 7, length: 0)
        ]
        session.storageDidChange()

        XCTAssertEqual(session.document.blocks, [
            .paragraph([.strong([.text("oXne")])]),
            .paragraph([.emphasis([.text("tYwo")])])
        ])
        XCTAssertEqual(bridge.markdownSelectedRanges.count, 2)
    }

    func testMultipleDeletionsWithinOneLeafKeepDocumentAndStorageSynchronized() {
        let bridge = FakeTextViewBridge()
        var published: [MarkdownDocument] = []
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "abcdef")) {
            published.append($0)
        }
        session.attach(to: bridge)
        let ranges = [NSRange(location: 1, length: 2), NSRange(location: 4, length: 2)]
        XCTAssertTrue(session.shouldReplaceCharacters(in: ranges, with: ["", ""]))
        for range in ranges.reversed() {
            bridge.markdownTextStorage.replaceCharacters(in: range, with: "")
        }
        let selections = [NSRange(location: 1, length: 0), NSRange(location: 2, length: 0)]
        bridge.markdownSelectedRanges = selections

        session.storageDidChange()

        let expected = MarkdownDocument(markdown: "ad")
        XCTAssertEqual(session.document, expected)
        XCTAssertEqual(published, [expected])
        XCTAssertEqual(bridge.markdownTextStorage.string, "ad\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, selections)
        XCTAssertEqual(session.projection.index.projectionUTF16Length, bridge.markdownTextStorage.length)
    }

    func testMultipleEditsWithinAndAcrossLeavesUseCombinedOffsets() {
        let bridge = FakeTextViewBridge()
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "**abcdef**\n\n*ghijkl*"))
        session.attach(to: bridge)
        let ranges = [
            NSRange(location: 1, length: 2), NSRange(location: 4, length: 2),
            NSRange(location: 8, length: 2), NSRange(location: 11, length: 2)
        ]
        let replacements = ["", "", "XYZ", "Q"]
        XCTAssertTrue(session.shouldReplaceCharacters(in: ranges, with: replacements))
        for (range, replacement) in zip(ranges, replacements).reversed() {
            let attributes = bridge.markdownTextStorage.attributes(at: range.location, effectiveRange: nil)
            bridge.replaceAttributedCharacters(in: range, with: NSAttributedString(string: replacement, attributes: attributes))
        }

        session.storageDidChange()

        XCTAssertEqual(session.document, MarkdownDocument(markdown: "**ad**\n\n*gXYZjQ*"))
        XCTAssertEqual(bridge.markdownTextStorage.string, "ad\ngXYZjQ\n")
        XCTAssertEqual(session.projection.index.projectionUTF16Length, bridge.markdownTextStorage.length)
    }

    func testMarkedTextDefersSemanticReconciliationUntilCompositionEnds() {
        let original = MarkdownDocument(blocks: [.paragraph([.text("old")])])
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 0)])
        let session = MarkdownEditingSession(document: original)
        session.attach(to: bridge)

        XCTAssertTrue(session.shouldReplaceCharacters(in: NSRange(location: 0, length: 3), with: "new"))
        bridge.markdownHasMarkedText = true
        bridge.replaceAttributedCharacters(
            in: NSRange(location: 0, length: 3),
            with: NSAttributedString(string: "new", attributes: bridge.markdownTextStorage.attributes(at: 0, effectiveRange: nil))
        )
        session.storageDidChange()
        XCTAssertEqual(session.document, original)

        bridge.markdownHasMarkedText = false
        session.compositionDidEnd()
        XCTAssertEqual(session.document.blocks, [.paragraph([.text("new")])])
    }

    func testCompositionWhoseFirstStepWasRecordedReconcilesTheCommittedLength() {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 2, length: 0)])
        var published: [MarkdownDocument] = []
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "abc\n\ndef")) { published.append($0) }
        session.attach(to: bridge)
        let attributes = bridge.markdownTextStorage.attributes(at: 0, effectiveRange: nil)
        var marked = NSRange(location: 2, length: 0)
        func step(_ text: String, isMarked: Bool) {
            bridge.markdownHasMarkedText = isMarked
            bridge.replaceAttributedCharacters(in: marked, with: NSAttributedString(string: text, attributes: attributes))
            marked.length = text.utf16.count
            bridge.markdownSelectedRanges = [NSRange(location: NSMaxRange(marked), length: 0)]
            session.storageDidChange()
        }

        // A platform may report the first step as an ordinary edit before marking it.
        XCTAssertTrue(session.shouldReplaceCharacters(in: marked, with: "n"))
        for text in ["n", "ni", "nih", "niha", "nihao"] {
            step(text, isMarked: true)
        }
        step("你好", isMarked: false)
        session.compositionDidEnd()

        let expected = MarkdownDocument(markdown: "ab你好c\n\ndef")
        XCTAssertEqual(session.document, expected)
        XCTAssertEqual(published, [expected])
        XCTAssertEqual(bridge.markdownTextStorage.string, "ab你好c\ndef\n")
        XCTAssertEqual(session.projection.index.projectionUTF16Length, bridge.markdownTextStorage.length)
    }

    func testExternalReplacementWinsAndCancelsDraft() {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 0)])
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "old"))
        session.attach(to: bridge)
        session.selectionDidChange()
        bridge.markdownHasMarkedText = true

        let replacement = MarkdownDocument(markdown: "replacement")
        session.replaceDocument(replacement)

        XCTAssertEqual(session.document, replacement)
        XCTAssertEqual(bridge.markdownTextStorage.string, "replacement\n")
    }

    func testLocalEchoDoesNotRebuildTheBridge() throws {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 3)])
        var emitted: MarkdownDocument?
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "old")) { emitted = $0 }
        session.attach(to: bridge)
        let replacementsBeforeCommand = bridge.replacementCount

        session.perform(.toggleInline(.strong))
        let replacementsAfterCommand = bridge.replacementCount
        session.replaceDocumentFromBinding(try XCTUnwrap(emitted))

        XCTAssertGreaterThan(replacementsAfterCommand, replacementsBeforeCommand)
        XCTAssertEqual(bridge.replacementCount, replacementsAfterCommand)
    }

    func testExplicitReplacementRestoresPreviouslyPublishedDocument() {
        let bridge = FakeTextViewBridge()
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "original"))
        session.attach(to: bridge)
        session.perform(.convertBlock(.heading(.one)))
        let saved = session.document
        session.perform(.convertBlock(.heading(.two)))

        session.replaceDocument(saved)

        XCTAssertEqual(session.document, saved)
        XCTAssertEqual(session.document.markdown, "# original\n")
        XCTAssertEqual(bridge.markdownTextStorage.string, "original\n")
    }

    func testAcknowledgedBindingValueCanBeRestoredAfterFurtherEdits() {
        let bridge = FakeTextViewBridge()
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "original"))
        session.attach(to: bridge)
        session.perform(.convertBlock(.heading(.one)))
        let saved = session.document
        XCTAssertTrue(session.acknowledgeBindingDocument(MarkdownDocument(markdown: saved.markdown)))
        session.perform(.convertBlock(.heading(.two)))
        XCTAssertTrue(session.acknowledgeBindingDocument(session.document))

        session.replaceDocumentFromBinding(saved)

        XCTAssertEqual(session.document, saved)
    }

    func testExternalReplacementClampsSelection() {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 20, length: 4)])
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "a much longer value"))
        session.attach(to: bridge)
        bridge.markdownSelectedRanges = [NSRange(location: 10, length: 5)]

        session.replaceDocument(MarkdownDocument(markdown: "x"))

        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 2, length: 0)])
    }

    func testCommandRegistersOneUndoUnitWithSelectionSnapshot() throws {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 1, length: 1)])
        let original = MarkdownDocument(markdown: "abc")
        let session = MarkdownEditingSession(document: original)
        session.attach(to: bridge)

        session.perform(.toggleInline(.strong))
        XCTAssertNotEqual(session.document, original)
        XCTAssertTrue(try XCTUnwrap(bridge.undoManager?.canUndo))

        bridge.undoManager?.undo()

        XCTAssertEqual(session.document, original)
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 1, length: 1)])
        XCTAssertFalse(try XCTUnwrap(bridge.undoManager?.canUndo))
        XCTAssertTrue(try XCTUnwrap(bridge.undoManager?.canRedo))
    }

    func testActiveBlockStyleCommandsToggleOffForCaretAndMultiBlockSelections() {
        let cases: [(MarkdownEditorCommand, String, String)] = [
            (.convertBlock(.blockquote), "> a", "a"),
            (.convertBlock(.blockquote), "> a\n>\n> b\n>\n> c", "a\n\nb\n\nc"),
            (.convertBlock(.heading(.two)), "## a", "a"),
            (.convertBlock(.heading(.two)), "## a\n\n## b", "a\n\nb"),
            (.convertList(.unordered), "- a", "a"),
            (.convertList(.unordered), "- a\n- b\n- c", "a\n\nb\n\nc"),
            (.convertList(.ordered(start: 1)), "1. a\n2. b", "a\n\nb"),
            (.convertList(.task), "- [ ] a\n- [x] b", "a\n\nb")
        ]
        for (command, source, expected) in cases {
            let original = MarkdownDocument(markdown: source)
            let bridge = FakeTextViewBridge()
            let session = MarkdownEditingSession(document: original)
            session.attach(to: bridge)
            bridge.markdownSelectedRanges = [NSRange(location: 0, length: bridge.markdownTextStorage.length - 1)]
            XCTAssertTrue(session.isActive(command), source)

            session.perform(command)
            XCTAssertEqual(session.document, MarkdownDocument(markdown: expected), source)
            XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown), session.document, source)
            XCTAssertFalse(session.isActive(command), source)

            bridge.undoManager?.undo()
            XCTAssertEqual(session.document, original, source)
            XCTAssertEqual(bridge.undoManager?.canUndo, false, source)
        }
    }

    func testBlockStyleCommandsOnMixedSelectionsApplyWithoutNesting() {
        let cases: [(MarkdownEditorCommand, String, String)] = [
            (.convertBlock(.blockquote), "> a\n\nb", "> a\n\n> b"),
            (.convertBlock(.heading(.two)), "## a\n\nb", "## a\n\n## b"),
            (.convertList(.unordered), "- a\n\n- [ ] b", "- a\n\n- b")
        ]
        for (command, source, expected) in cases {
            let bridge = FakeTextViewBridge()
            let session = MarkdownEditingSession(document: MarkdownDocument(markdown: source))
            session.attach(to: bridge)
            bridge.markdownSelectedRanges = [NSRange(location: 0, length: bridge.markdownTextStorage.length - 1)]
            XCTAssertFalse(session.isActive(command), source)

            session.perform(command)
            XCTAssertEqual(session.document.markdown, MarkdownDocument(markdown: expected).markdown, source)
            XCTAssertTrue(session.isActive(command), source)
        }
    }

    func testTableAttachmentChangeUpdatesDocumentAndSupportsUndo() throws {
        let original = MarkdownDocument(markdown: "| Name |\n| --- |\n| Old |")
        let bridge = FakeTextViewBridge()
        var emitted: [MarkdownDocument] = []
        let session = MarkdownEditingSession(document: original) { emitted.append($0) }
        session.attach(to: bridge)

        let originalAttachment = try XCTUnwrap(
            attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self)
        )
        let replacementCount = bridge.replacementCount
        originalAttachment.controller.updateCell(
            at: MarkdownTableCellPosition(section: .body(row: 0), column: 0),
            source: "**New**"
        )

        guard case let .table(table) = session.document.blocks.first else {
            return XCTFail("Expected the table block to remain a table")
        }
        XCTAssertEqual(table.rows[0].cells[0].content, [.strong([.text("New")])])
        XCTAssertEqual(emitted.last, session.document)
        XCTAssertEqual(bridge.replacementCount, replacementCount)
        XCTAssertTrue(
            originalAttachment === attachment(
                in: bridge.markdownTextStorage,
                ofType: MarkdownTableAttachment.self
            )
        )
        XCTAssertTrue(try XCTUnwrap(bridge.undoManager?.canUndo))

        bridge.undoManager?.undo()

        XCTAssertEqual(session.document, original)
    }

    func testTableChangesOnlyReplaceTableMappingsAndPreserveNativeIdentities() throws {
        let table = try XCTUnwrap(MarkdownDocument(markdown: "| Name |\n| --- |\n| Old |").blocks.first)
        let containers: [MarkdownBlock] = [
            table,
            .blockquote([table]),
            .list(MarkdownList(kind: .ordered(start: 10), isTight: false, items: [
                MarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("item")]), .blockquote([table])])
            ]))
        ]
        for container in containers {
            let document = MarkdownDocument(blocks: [
                .paragraph([.strong([.text("Before")])]),
                container,
                .paragraph([.image(source: "image.png", title: nil, children: [.text("alt")])]),
                .paragraph([.text("After 👩‍👩‍👧‍👦")])
            ])
            let bridge = FakeTextViewBridge()
            let session = MarkdownEditingSession(document: document)
            session.attach(to: bridge)
            let originalUnits = session.projection.index.units
            let tableAttachment = try XCTUnwrap(attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self))
            let originalImage = try XCTUnwrap(attachment(in: bridge.markdownTextStorage, ofType: MarkdownImageAttachment.self))
            let replacements = bridge.replacementCount
            for source in ["**Longer 👩‍👩‍👧‍👦**", "x"] {
                tableAttachment.controller.updateCell(
                    at: MarkdownTableCellPosition(section: .body(row: 0), column: 0), source: source
                )
                let expected = MarkdownProjectionBuilder().build(document: session.document)
                let actualUnits = session.projection.index.units
                XCTAssertEqual(session.projection.source, expected.source)
                XCTAssertEqual(session.projection.index.sourceUTF16Length, expected.index.sourceUTF16Length)
                XCTAssertEqual(actualUnits.map(\.id), originalUnits.map(\.id))
                XCTAssertEqual(actualUnits.map(\.projectionRange), expected.index.units.map(\.projectionRange))
                XCTAssertEqual(actualUnits.map(\.sourceRange), expected.index.units.map(\.sourceRange))
                XCTAssertEqual(actualUnits.map(\.segments), expected.index.units.map(\.segments))
                XCTAssertEqual(bridge.replacementCount, replacements)
                XCTAssertTrue(originalImage === attachment(in: bridge.markdownTextStorage, ofType: MarkdownImageAttachment.self))
                XCTAssertTrue(tableAttachment === attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self))
            }
            // A native table can append a row without changing its outer attachment range.
            tableAttachment.controller.moveForward(from: MarkdownTableCellPosition(section: .body(row: 0), column: 0))
            let expected = MarkdownProjectionBuilder().build(document: session.document)
            XCTAssertEqual(session.projection.index.units.map(\.segments), expected.index.units.map(\.segments))
            XCTAssertEqual(session.projection.source, expected.source)
        }
    }

    func testTableEditRefreshesDeferredRichTextSourceMapsWithoutReplacingStorage() throws {
        let document = MarkdownDocument(markdown: "**Before**\n\n| Name |\n| --- |\n| Old |\n\nAfter")
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 2, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)
        session.selectionDidChange()
        let originalIDs = session.projection.index.units.map(\.id)
        let table = try XCTUnwrap(attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self))
        let insertion = "😀*"
        XCTAssertTrue(session.shouldReplaceCharacters(in: NSRange(location: 2, length: 0), with: insertion))
        bridge.replaceAttributedCharacters(
            in: NSRange(location: 2, length: 0),
            with: NSAttributedString(string: insertion, attributes: bridge.markdownTypingAttributes)
        )
        bridge.markdownSelectedRanges = [NSRange(location: 5, length: 0)]
        session.storageDidChange()
        let replacements = bridge.replacementCount
        for source in ["A longer cell", "x"] {
            table.controller.updateCell(at: MarkdownTableCellPosition(section: .body(row: 0), column: 0), source: source)
            let expected = MarkdownProjectionBuilder().build(document: session.document)
            XCTAssertEqual(session.projection.index.units.map(\.segments), expected.index.units.map(\.segments))
            XCTAssertEqual(session.projection.index.units.map(\.id), originalIDs)
            XCTAssertEqual(session.projection.source, expected.source)
            XCTAssertEqual(session.projection.index.sourceUTF16Length, expected.index.sourceUTF16Length)
            XCTAssertEqual(bridge.replacementCount, replacements)
            XCTAssertTrue(table === attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self))
        }
    }

    func testTableCellFocusAnchorsOuterSelectionAndSurvivesProjectionRebuild() throws {
        let document = MarkdownDocument(markdown: """
        Before

        | Name |
        | --- |
        | Editor |
        """)
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 0)])
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)
        let tableAttachment = try XCTUnwrap(
            attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self)
        )
        let position = MarkdownTableCellPosition(section: .body(row: 0), column: 0)
        let cellSelection = MarkdownTableCellSelection(
            position: position,
            range: NSRange(location: 3, length: 0)
        )
        let tableUnit = try XCTUnwrap(session.projection.index.unit(at: EditorNodePath([.block(1)])))

        tableAttachment.controller.updateSelection(at: position, range: cellSelection.range)

        XCTAssertEqual(
            bridge.markdownSelectedRanges,
            [NSRange(location: tableUnit.projectionRange.location, length: 0)]
        )

        session.replaceTheme(.gitHub)

        let rebuiltAttachment = try XCTUnwrap(
            attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self)
        )
        XCTAssertEqual(rebuiltAttachment.controller.activeSelection, cellSelection)
        XCTAssertEqual(
            bridge.markdownSelectedRanges,
            [NSRange(location: tableUnit.projectionRange.location, length: 0)]
        )
    }

    func testTableCommandUsesTheFocusedNestedCellAndRestoresItsDestination() throws {
        let document = MarkdownDocument(markdown: "| Name |\n| --- |\n| Editor |")
        let bridge = FakeTextViewBridge()
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)
        let tableAttachment = try XCTUnwrap(
            attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self)
        )
        tableAttachment.controller.updateSelection(
            at: MarkdownTableCellPosition(section: .body(row: 0), column: 0),
            range: NSRange(location: 2, length: 0)
        )

        session.perform(.insertTableColumn)

        guard case let .table(table) = session.document.blocks.first else {
            return XCTFail("Expected a table")
        }
        XCTAssertEqual(table.alignments.count, 2)
        let rebuiltAttachment = try XCTUnwrap(
            attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self)
        )
        XCTAssertEqual(
            rebuiltAttachment.controller.activeSelection?.position,
            MarkdownTableCellPosition(section: .body(row: 0), column: 1)
        )
    }

    func testInlineStyleIgnoresOnlyUnstyledWhitespaceRuns() {
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: """
        **bold** **text**

        **a**\u{00A0}\t**b**

        **bold** 😀 **text**

        *bold* **text**
        """))
        let bridge = FakeTextViewBridge()
        session.attach(to: bridge)
        let string = bridge.markdownTextStorage.string as NSString
        func strongIsActive(_ text: String) -> Bool {
            bridge.markdownSelectedRanges = [string.range(of: text)]
            return session.isActive(.toggleInline(.strong))
        }

        XCTAssertTrue(strongIsActive("bold text"))
        XCTAssertTrue(strongIsActive("a\u{00A0}\tb"))
        XCTAssertFalse(strongIsActive("bold 😀 text"))
        XCTAssertFalse(strongIsActive("😀"))
        XCTAssertTrue(strongIsActive(" text"))
        let lastParagraph = string.range(of: "bold text", options: .backwards)
        bridge.markdownSelectedRanges = [lastParagraph]
        XCTAssertNotEqual(lastParagraph, string.range(of: "bold text"))
        XCTAssertFalse(session.isActive(.toggleInline(.strong)))
    }

    func testTableCellInlineStylesFollowCellEditsAndThemeChanges() throws {
        let document = MarkdownDocument(markdown: "| Name |\n| --- |\n| **bold** plain |")
        let bridge = FakeTextViewBridge()
        let session = MarkdownEditingSession(document: document)
        session.attach(to: bridge)
        let position = MarkdownTableCellPosition(section: .body(row: 0), column: 0)
        let boldRange = NSRange(location: 0, length: 4)
        let plainRange = NSRange(location: 5, length: 5)
        func select(_ range: NSRange) throws {
            let table = try XCTUnwrap(attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self))
            table.controller.updateSelection(at: position, range: range)
        }

        try select(boldRange)
        XCTAssertTrue(session.isActive(.toggleInline(.strong)))
        XCTAssertFalse(session.isActive(.toggleInline(.emphasis)))
        try select(plainRange)
        XCTAssertFalse(session.isActive(.toggleInline(.strong)))

        let table = try XCTUnwrap(attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self))
        table.controller.updateCell(at: position, source: "bold **plain**")
        try select(boldRange)
        try select(plainRange)
        XCTAssertTrue(session.isActive(.toggleInline(.strong)))
        try select(boldRange)
        XCTAssertFalse(session.isActive(.toggleInline(.strong)))

        session.replaceTheme(.gitHub)
        try select(plainRange)
        XCTAssertTrue(session.isActive(.toggleInline(.strong)))
        XCTAssertFalse(session.isActive(.toggleInline(.code)))
    }

    func testTypingAfterFinalTableCreatesVisibleParagraph() {
        let original = MarkdownDocument(markdown: "| Name |\n| --- |\n| Old |")
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 2, length: 0)])
        let session = MarkdownEditingSession(document: original)
        session.attach(to: bridge)

        XCTAssertFalse(
            session.shouldReplaceCharacters(
                in: NSRange(location: 2, length: 0),
                with: "x"
            )
        )

        XCTAssertEqual(session.document.blocks, original.blocks + [.paragraph([.text("x")])])
        XCTAssertEqual(bridge.markdownTextStorage.string, "\u{fffc}\nx\n")
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: 3, length: 0)])
    }

    func testDelayedTableBindingEchoesDoNotReplaceNewerCellEdits() throws {
        let original = MarkdownDocument(markdown: "| Name |\n| --- |\n| Old |")
        let bridge = FakeTextViewBridge()
        var emitted: [MarkdownDocument] = []
        let session = MarkdownEditingSession(document: original) { emitted.append($0) }
        session.attach(to: bridge)
        let tableAttachment = try XCTUnwrap(
            attachment(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self)
        )
        let position = MarkdownTableCellPosition(section: .body(row: 0), column: 0)

        tableAttachment.controller.updateCell(at: position, source: "Old1")
        tableAttachment.controller.updateCell(at: position, source: "Old12")
        XCTAssertEqual(emitted.count, 2)
        let replacementCount = bridge.replacementCount

        session.replaceDocumentFromBinding(MarkdownDocument(markdown: emitted[0].markdown))

        XCTAssertEqual(session.document, emitted[1])
        XCTAssertEqual(bridge.replacementCount, replacementCount)

        session.replaceDocumentFromBinding(MarkdownDocument(markdown: emitted[1].markdown))

        XCTAssertEqual(session.document, emitted[1])
        XCTAssertEqual(bridge.replacementCount, replacementCount)
    }

    func testImageAttachmentChangeUpdatesNestedImageAndSupportsUndo() throws {
        let original = MarkdownDocument(blocks: [
            .paragraph([
                .strong([
                    .image(source: "old.png", title: nil, children: [.text("old alt")])
                ])
            ])
        ])
        let bridge = FakeTextViewBridge()
        var emitted: MarkdownDocument?
        let session = MarkdownEditingSession(document: original) { emitted = $0 }
        session.attach(to: bridge)

        let attachment = try XCTUnwrap(
            attachment(in: bridge.markdownTextStorage, ofType: MarkdownImageAttachment.self)
        )
        attachment.updateMetadata(
            MarkdownImageMetadata(source: "new.png", title: "New", altText: "new alt")
        )

        guard case let .paragraph(content) = session.document.blocks.first,
              case let .strong(children) = content.first,
              case let .image(source, title, imageChildren) = children.first else {
            return XCTFail("Expected the nested image structure to be preserved")
        }
        XCTAssertEqual(source, "new.png")
        XCTAssertEqual(title, "New")
        XCTAssertEqual(imageChildren, [.text("new alt")])
        XCTAssertEqual(emitted, session.document)
        XCTAssertTrue(try XCTUnwrap(bridge.undoManager?.canUndo))

        bridge.undoManager?.undo()

        XCTAssertEqual(session.document, original)
    }

    func testClipboardPayloadPreservesCompleteInlineMarkdown() throws {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 4)])
        let session = MarkdownEditingSession(
            document: MarkdownDocument(blocks: [.paragraph([.strong([.text("bold")])])])
        )
        session.attach(to: bridge)

        let payload = try XCTUnwrap(session.clipboardPayload())

        XCTAssertEqual(payload.markdown, "**bold**")
        XCTAssertEqual(payload.plainText, "bold")
    }

    func testPastePrefersMarkdownAndSupportsUndo() throws {
        let original = MarkdownDocument(markdown: "old")
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 0)])
        let session = MarkdownEditingSession(document: original)
        session.attach(to: bridge)

        XCTAssertTrue(session.paste(MarkdownClipboardPayload(markdown: "**new**", plainText: "new")))
        XCTAssertEqual(
            session.document.blocks,
            [.paragraph([.strong([.text("new")]), .text("old")])]
        )
        XCTAssertTrue(try XCTUnwrap(bridge.undoManager?.canUndo))

        bridge.undoManager?.undo()

        XCTAssertEqual(session.document, original)
    }

    func testPlainTextPasteInsertsMarkdownPunctuationLiterally() {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 0)])
        let session = MarkdownEditingSession(document: MarkdownDocument(blocks: [.paragraph([])]))
        session.attach(to: bridge)
        session.selectionDidChange()

        XCTAssertTrue(session.paste(MarkdownClipboardPayload(plainText: "**literal**")))
        XCTAssertEqual(session.document.blocks, [.paragraph([.text("**literal**")])])
        XCTAssertEqual(bridge.markdownTextStorage.string, "**literal**\n")
    }

    func testPlainTextPasteLineEndingsSurviveSaveAndReload() {
        let paragraphs: [MarkdownBlock] = [.paragraph([.text("one")]), .paragraph([.text("two")])]
        let softBreak: [MarkdownBlock] = [.paragraph([.text("one"), .softBreak, .text("two")])]
        let cases: [(pasted: String, expected: [MarkdownBlock])] = [
            ("one\n\ntwo", paragraphs),
            ("one\r\n\r\ntwo", paragraphs),
            ("one\r\rtwo", paragraphs),
            ("one\u{2029}\u{2029}two", paragraphs),
            ("one\ntwo", softBreak),
            ("one\r\ntwo", softBreak),
            ("one\rtwo", softBreak),
            ("one\u{2029}two", softBreak)
        ]
        for (pasted, expected) in cases {
            let name = pasted.debugDescription
            let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 0, length: 0)])
            let session = MarkdownEditingSession(document: MarkdownDocument(blocks: [.paragraph([])]))
            session.attach(to: bridge)
            session.selectionDidChange()

            XCTAssertTrue(session.paste(MarkdownClipboardPayload(plainText: pasted)), name)

            XCTAssertEqual(session.document.blocks, expected, name)
            XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown).blocks, expected, name)
            XCTAssertFalse(session.document.markdown.contains("\r"), name)
            XCTAssertFalse(bridge.markdownTextStorage.string.unicodeScalars.contains("\r"), name)
            XCTAssertEqual(session.projection.string, bridge.markdownTextStorage.string, name)
        }
    }

    func testPlainTextParagraphsPasteIntoAParagraphAndUndo() {
        let original = MarkdownDocument(markdown: "ab")
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 1, length: 0)])
        let session = MarkdownEditingSession(document: original)
        session.attach(to: bridge)
        session.selectionDidChange()

        XCTAssertTrue(session.paste(MarkdownClipboardPayload(plainText: "**one**\r\nline\r\n  \r\ntwo")))

        XCTAssertEqual(session.document.markdown, "a\\*\\*one\\*\\*\nline\n\ntwob\n")
        XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown).blocks, [
            .paragraph([.text("a**one**"), .softBreak, .text("line")]),
            .paragraph([.text("twob")])
        ])
        XCTAssertEqual(bridge.markdownTextStorage.string, "a**one**\nline\ntwob\n")

        bridge.undoManager?.undo()

        XCTAssertEqual(session.document, original)
    }

    func testPlainTextPasteKeepsBlankLinesInsideACodeBlock() {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 1, length: 0)])
        let session = MarkdownEditingSession(document: MarkdownDocument(markdown: "```\nab\n```"))
        session.attach(to: bridge)
        session.selectionDidChange()

        XCTAssertTrue(session.paste(MarkdownClipboardPayload(plainText: "x\r\n\r\ny")))

        let expected: [MarkdownBlock] = [.codeBlock(info: nil, content: "ax\n\nyb\n")]
        XCTAssertEqual(session.document.blocks, expected)
        XCTAssertEqual(MarkdownDocument(markdown: session.document.markdown).blocks, expected)
    }

    func testMarkdownPasteSplicesMultipleSemanticBlocks() {
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: 2, length: 0)])
        let session = MarkdownEditingSession(
            document: MarkdownDocument(blocks: [.paragraph([.text("beforeafter")])])
        )
        session.attach(to: bridge)

        XCTAssertTrue(session.paste(MarkdownClipboardPayload(
            markdown: "# Heading\n\n- one\n- two",
            plainText: "Heading\none\ntwo"
        )))
        XCTAssertEqual(session.document.markdown, "# beHeading\n\n  - one\n  - two\n\nforeafter\n")
        XCTAssertFalse(bridge.markdownTextStorage.string.contains("#"))
        XCTAssertFalse(bridge.markdownTextStorage.string.contains("- "))
    }

    func testTypingAroundComposedUnicodeKeepsUTF16Selection() {
        let text = "A👩‍👩‍👧‍👦e\u{301}Z"
        let emojiEnd = ("A👩‍👩‍👧‍👦" as NSString).length
        let bridge = FakeTextViewBridge(selectedRanges: [NSRange(location: emojiEnd, length: 0)])
        let session = MarkdownEditingSession(
            document: MarkdownDocument(blocks: [.paragraph([.strong([.text(text)])])])
        )
        session.attach(to: bridge)
        session.selectionDidChange()

        XCTAssertTrue(session.shouldReplaceCharacters(
            in: NSRange(location: emojiEnd, length: 0),
            with: "X"
        ))
        bridge.replaceAttributedCharacters(
            in: NSRange(location: emojiEnd, length: 0),
            with: NSAttributedString(string: "X", attributes: bridge.markdownTypingAttributes)
        )
        bridge.markdownSelectedRanges = [NSRange(location: emojiEnd + 1, length: 0)]
        session.storageDidChange()

        XCTAssertEqual(session.document.blocks, [
            .paragraph([.strong([.text("A👩‍👩‍👧‍👦Xe\u{301}Z")])])
        ])
        XCTAssertEqual(bridge.markdownSelectedRanges, [NSRange(location: emojiEnd + 1, length: 0)])
    }

    private func attachment<Attachment: NSTextAttachment>(
        in attributedString: NSAttributedString,
        ofType type: Attachment.Type
    ) -> Attachment? {
        var result: Attachment?
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            guard let attachment = value as? Attachment else {
                return
            }
            result = attachment
            stop.pointee = true
        }
        return result
    }

    private func assertPlainTextMappingRoundTrips(
        path: EditorNodePath,
        in projection: DocumentProjection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let unit = projection.index.unit(at: path) else {
            return XCTFail("Expected projection unit", file: file, line: line)
        }
        for relativeOffset in 0 ... unit.projectionRange.length {
            let projectionOffset = unit.projectionRange.location + relativeOffset
            let anchor = projection.index.sourceAnchor(atProjectionUTF16Offset: projectionOffset)
            XCTAssertEqual(
                anchor?.utf16Offset,
                unit.sourceRange.location + relativeOffset,
                file: file,
                line: line
            )
            XCTAssertEqual(
                anchor.flatMap(projection.index.projectionUTF16Offset),
                projectionOffset,
                file: file,
                line: line
            )
        }
    }
}

@MainActor private final class FakeTextViewBridge: TextViewBridge {
    let markdownTextStorage = NSTextStorage()
    var markdownSelectedRanges: [NSRange]
    var markdownTypingAttributes: [NSAttributedString.Key: Any] = [:]
    var markdownHasMarkedText = false
    var markdownIsFirstResponder = false
    let undoManager: UndoManager? = UndoManager()
    private(set) var replacementCount = 0

    init(selectedRanges: [NSRange] = [NSRange(location: 0, length: 0)]) {
        self.markdownSelectedRanges = selectedRanges
    }

    func replaceAttributedCharacters(in range: NSRange, with replacement: NSAttributedString) {
        replacementCount += 1
        markdownTextStorage.replaceCharacters(in: range, with: replacement)
    }
}
