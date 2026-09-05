import Foundation
@testable import MarkdownUIEditor
import XCTest

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor final class MarkdownEditingSessionTests: XCTestCase {
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
