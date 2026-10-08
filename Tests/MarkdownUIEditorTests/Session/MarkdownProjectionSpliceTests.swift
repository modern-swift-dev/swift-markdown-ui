import Foundation
@testable import MarkdownUIEditor
import XCTest

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// Structural edits replace only changed blocks, so after each one the native
/// text and index must match a projection built from scratch.
@MainActor final class MarkdownProjectionSpliceTests: XCTestCase {
    func testReturnInEachBlockKindMatchesFullProjection() throws {
        let cases: [(String, (MarkdownBlock) -> Bool, Int)] = [
            ("heading", {
                if case .heading = $0 {
                    true
                } else {
                    false
                }
            }, 3),
            ("paragraph", {
                if case .paragraph = $0 {
                    true
                } else {
                    false
                }
            }, 5),
            ("blockquote", {
                if case .blockquote = $0 {
                    true
                } else {
                    false
                }
            }, 5),
            ("list", {
                if case .list = $0 {
                    true
                } else {
                    false
                }
            }, 2)
        ]
        for (name, matches, offset) in cases {
            let (session, bridge) = makeSession()
            let unit = try firstUnit(in: session, where: matches)
            bridge.resetReplacements()
            edit(session, bridge, NSRange(location: unit.projectionRange.location + offset, length: 0), "\n")
            assertMatchesFullProjection(session, bridge, "Return in \(name)")
        }
    }

    func testReturnAtLeafBoundariesMatchesFullProjection() throws {
        let (session, bridge) = makeSession()
        for unit in session.projection.index.units.prefix(8) {
            let current = try XCTUnwrap(session.projection.index.unit(atProjectionUTF16Offset: unit.projectionRange.location))
            edit(session, bridge, NSRange(location: current.projectionRange.upperBound - 1, length: 0), "\n")
            assertMatchesFullProjection(session, bridge, "Return at end of \(current.path)")
        }
        let first = try XCTUnwrap(session.projection.index.units.first)
        edit(session, bridge, NSRange(location: first.projectionRange.location, length: 0), "\n")
        assertMatchesFullProjection(session, bridge, "Return at document start")
    }

    func testBackspaceJoinsMatchFullProjection() throws {
        let (session, bridge) = makeSession()
        for _ in 0 ..< 6 {
            let units = session.projection.index.units
            guard units.count > 1 else {
                break
            }
            let first = units[0]
            bridge.resetReplacements()
            edit(session, bridge, NSRange(location: first.projectionRange.upperBound - 1, length: 1), "")
            assertMatchesFullProjection(session, bridge, "join after \(first.path)", requiresSplice: false)
        }
        let list = try firstUnit(in: session) {
            if case .list = $0 {
                true
            } else {
                false
            }
        }
        edit(session, bridge, NSRange(location: list.projectionRange.upperBound - 1, length: 1), "")
        assertMatchesFullProjection(session, bridge, "join list items", requiresSplice: false)
    }

    func testToolbarCommandsMatchFullProjection() throws {
        let commands: [(String, MarkdownEditorCommand, (MarkdownBlock) -> Bool)] = [
            ("heading", .convertBlock(.heading(.two)), {
                if case .paragraph = $0 {
                    true
                } else {
                    false
                }
            }),
            ("paragraph", .convertBlock(.paragraph), {
                if case .heading = $0 {
                    true
                } else {
                    false
                }
            }),
            ("quote", .convertBlock(.blockquote), {
                if case .paragraph = $0 {
                    true
                } else {
                    false
                }
            }),
            ("code", .convertBlock(.code(info: nil)), {
                if case .heading = $0 {
                    true
                } else {
                    false
                }
            }),
            ("ordered", .convertList(.ordered(start: 3)), {
                if case .paragraph = $0 {
                    true
                } else {
                    false
                }
            }),
            ("task", .convertList(.task), {
                if case .list = $0 {
                    true
                } else {
                    false
                }
            }),
            ("strong", .toggleInline(.strong), {
                if case .heading = $0 {
                    true
                } else {
                    false
                }
            }),
            ("rule", .insertThematicBreak, {
                if case .paragraph = $0 {
                    true
                } else {
                    false
                }
            }),
            ("table", .insertTable(columns: 2, bodyRows: 1), {
                if case .heading = $0 {
                    true
                } else {
                    false
                }
            }),
            ("image", .insertImage(source: "new.png", title: nil, alt: "new"), {
                if case .paragraph = $0 {
                    true
                } else {
                    false
                }
            }),
            ("indent", .indent, {
                if case let .list(list) = $0 {
                    list.items.first?.taskState == nil
                } else {
                    false
                }
            }),
            ("outdent", .outdent, {
                if case .list = $0 {
                    true
                } else {
                    false
                }
            })
        ]
        for (name, command, matches) in commands {
            let (session, bridge) = makeSession()
            let unit = try lastUnit(in: session, where: matches)
            bridge.markdownSelectedRanges = [NSRange(location: unit.projectionRange.location + 1, length: 2)]
            bridge.resetReplacements()
            let before = session.document
            session.perform(command)
            XCTAssertNotEqual(session.document, before, name)
            assertMatchesFullProjection(session, bridge, name)
        }
    }

    func testTaskToggleUndoAndRedoMatchFullProjection() throws {
        let (session, bridge) = makeSession()
        let undoManager = try XCTUnwrap(bridge.undoManager)
        undoManager.groupsByEvent = false
        var documents = [session.document]

        func step(_ name: String, _ change: () throws -> Void) rethrows {
            undoManager.beginUndoGrouping()
            try change()
            undoManager.endUndoGrouping()
            documents.append(session.document)
            assertMatchesFullProjection(session, bridge, name)
        }

        let task = try firstUnit(in: session) { block in
            guard case let .list(list) = block else {
                return false
            }
            return list.items.first?.taskState != nil
        }
        try step("toggle task") {
            XCTAssertTrue(session.toggleTask(atProjectionUTF16Offset: task.projectionRange.location))
        }
        let heading = try firstUnit(in: session) {
            if case .heading = $0 {
                true
            } else {
                false
            }
        }
        step("return") {
            edit(session, bridge, NSRange(location: heading.projectionRange.location + 2, length: 0), "\n")
        }
        let paragraph = try lastUnit(in: session) {
            if case .paragraph = $0 {
                true
            } else {
                false
            }
        }
        step("convert") {
            bridge.markdownSelectedRanges = [NSRange(location: paragraph.projectionRange.location, length: 0)]
            session.perform(.convertList(.unordered))
        }

        for expected in documents.reversed().dropFirst() {
            bridge.resetReplacements()
            undoManager.undo()
            XCTAssertEqual(session.document, expected)
            assertMatchesFullProjection(session, bridge, "undo")
        }
        for expected in documents.dropFirst() {
            bridge.resetReplacements()
            undoManager.redo()
            XCTAssertEqual(session.document, expected)
            assertMatchesFullProjection(session, bridge, "redo")
        }
    }

    func testTypingAtDocumentEndMatchesFullProjection() {
        let (session, bridge) = makeSession()
        for character in ["a", "b", "\n", "c"] {
            let end = bridge.markdownTextStorage.length
            bridge.markdownSelectedRanges = [NSRange(location: end, length: 0)]
            edit(session, bridge, NSRange(location: end, length: 0), character)
            assertMatchesFullProjection(session, bridge, "typing \(character)")
        }
    }

    func testNativeTypingBeforeStructuralEditIsRenderedAgain() throws {
        let (session, bridge) = makeSession()
        let heading = try firstUnit(in: session) {
            if case .heading = $0 {
                true
            } else {
                false
            }
        }
        let quote = try firstUnit(in: session) {
            if case .blockquote = $0 {
                true
            } else {
                false
            }
        }
        edit(session, bridge, NSRange(location: heading.projectionRange.location + 1, length: 0), "Z")
        edit(session, bridge, NSRange(location: quote.projectionRange.location + 2, length: 0), "Y")
        XCTAssertTrue(session.document.markdown.contains("HZeading"))
        XCTAssertTrue(session.document.markdown.contains("QYuote"))

        let paragraph = try lastUnit(in: session) {
            if case .paragraph = $0 {
                true
            } else {
                false
            }
        }
        bridge.resetReplacements()
        edit(session, bridge, NSRange(location: paragraph.projectionRange.location + 3, length: 0), "\n")
        assertMatchesFullProjection(session, bridge, "Return after typing")

        // Typing again after the splice reconciles against the spliced index.
        let tail = try lastUnit(in: session) {
            if case .paragraph = $0 {
                true
            } else {
                false
            }
        }
        edit(session, bridge, NSRange(location: tail.projectionRange.location, length: 0), "X")
        XCTAssertTrue(session.document.markdown.contains("Xal"))
        let lastHeading = try lastUnit(in: session) {
            if case .heading = $0 {
                true
            } else {
                false
            }
        }
        bridge.markdownSelectedRanges = [NSRange(location: lastHeading.projectionRange.location, length: 0)]
        let before = session.document
        session.perform(.convertBlock(.paragraph))
        XCTAssertNotEqual(session.document, before)
        assertMatchesFullProjection(session, bridge, "command after typing", requiresSplice: false)
    }

    func testRejectedNativeEditRendersOnlyItsBlockAgain() throws {
        let (session, bridge) = makeSession()
        let document = session.document
        let rule = try firstUnit(in: session) {
            if case .thematicBreak = $0 {
                true
            } else {
                false
            }
        }
        bridge.resetReplacements()
        edit(session, bridge, NSRange(location: rule.projectionRange.location, length: 0), "x")
        XCTAssertEqual(session.document, document)
        assertMatchesFullProjection(session, bridge, "rejected edit")
    }

    func testAttachmentsAfterInsertedBlocksReportTheirMovedPaths() throws {
        let (session, bridge) = makeSession()
        let heading = try firstUnit(in: session) {
            if case .heading = $0 {
                true
            } else {
                false
            }
        }
        edit(session, bridge, NSRange(location: heading.projectionRange.location + 2, length: 0), "\n")
        edit(session, bridge, NSRange(location: heading.projectionRange.location + 1, length: 0), "\n")
        assertMatchesFullProjection(session, bridge, "inserted blocks")

        let table = try XCTUnwrap(attachments(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self).first)
        bridge.resetReplacements()
        table.controller.updateCell(at: MarkdownTableCellPosition(section: .body(row: 0), column: 0), source: "moved")
        XCTAssertTrue(session.document.markdown.contains("|moved|"), session.document.markdown)
        XCTAssertEqual(bridge.replacements, [], "A table edit keeps its attachment in place")
        assertMatchesFullProjection(session, bridge, "table edit", requiresSplice: false)

        let image = try XCTUnwrap(attachments(in: bridge.markdownTextStorage, ofType: MarkdownImageAttachment.self).first)
        var metadata = image.metadata
        metadata.source = "moved.png"
        image.updateMetadata(metadata)
        XCTAssertTrue(session.document.markdown.contains("(moved.png"), session.document.markdown)
        assertMatchesFullProjection(session, bridge, "image edit")

        // Removing blocks moves paths back.
        let first = try XCTUnwrap(session.projection.index.units.first)
        edit(session, bridge, NSRange(location: first.projectionRange.upperBound - 1, length: 1), "")
        let quotedTable = try XCTUnwrap(attachments(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self).last)
        quotedTable.controller.updateCell(at: MarkdownTableCellPosition(section: .body(row: 0), column: 1), source: "quoted")
        XCTAssertTrue(session.document.markdown.contains("|a|quoted|"), session.document.markdown)
        assertMatchesFullProjection(session, bridge, "quoted table edit", requiresSplice: false)
    }

    func testTableCommandsMatchFullProjectionAndKeepCellFocus() throws {
        let (session, bridge) = makeSession()
        let table = try XCTUnwrap(attachments(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self).first)
        let position = MarkdownTableCellPosition(section: .body(row: 0), column: 1)
        table.controller.updateSelection(at: position, range: NSRange(location: 0, length: 0))
        XCTAssertTrue(session.hasActiveTableSelection)

        for command in [MarkdownEditorCommand.insertTableRow, .insertTableColumn, .deleteTableRow] {
            bridge.resetReplacements()
            session.perform(command)
            assertMatchesFullProjection(session, bridge, "\(command)")
            let tables = attachments(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self)
            XCTAssertNotNil(tables.first?.controller.activeSelection, "\(command)")
            XCTAssertNil(tables.last?.controller.activeSelection, "\(command)")
        }
    }

    func testUnchangedTablesKeepTheirAttachmentsWhenRenderedAgain() throws {
        let (session, bridge) = makeSession()
        let tables = attachments(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self)
        XCTAssertEqual(tables.count, 2)
        let quoteIndex = try XCTUnwrap(session.document.blocks.lastIndex {
            if case .blockquote = $0 {
                true
            } else {
                false
            }
        })
        guard case let .blockquote(children) = session.document.blocks[quoteIndex] else {
            return XCTFail("Expected the quoted table")
        }
        var document = session.document
        document.blocks[quoteIndex] = .blockquote([.paragraph([.text("Above")])] + children)
        bridge.resetReplacements()
        session.replaceDocument(document)
        assertMatchesFullProjection(session, bridge, "quote around table")
        XCTAssertTrue(attachments(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self).elementsEqual(tables, by: ===))

        // A kept attachment reports edits at its new path.
        tables[1].controller.updateCell(at: MarkdownTableCellPosition(section: .body(row: 0), column: 1), source: "kept")
        XCTAssertTrue(session.document.markdown.contains("|a|kept|"), session.document.markdown)
        assertMatchesFullProjection(session, bridge, "kept table edit", requiresSplice: false)

        session.replaceTheme(.gitHub)
        assertMatchesFullProjection(session, bridge, "theme", requiresSplice: false)
        XCTAssertTrue(attachments(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self).elementsEqual(tables, by: ===))

        // A changed table gets a new attachment.
        var changed = session.document
        guard case var .table(table) = changed.blocks[quoteIndex - 2] else {
            return XCTFail("Expected the first table")
        }
        table.rows.removeLast()
        changed.blocks[quoteIndex - 2] = .table(table)
        bridge.resetReplacements()
        session.replaceDocument(changed)
        assertMatchesFullProjection(session, bridge, "changed table")
        let replaced = attachments(in: bridge.markdownTextStorage, ofType: MarkdownTableAttachment.self)
        XCTAssertFalse(replaced[0] === tables[0])
        XCTAssertTrue(replaced[1] === tables[1])
    }

    func testConfigurationChangesStillReplaceAllText() {
        let (session, bridge) = makeSession()
        session.synchronizeFromBinding(
            document: MarkdownDocument(markdown: ProjectionComparison.richMarkdown + "\n\nmore"),
            theme: .gitHub,
            baseURL: nil,
            imageProvider: nil
        )
        XCTAssertEqual(bridge.replacements.last?.location, 0)
        XCTAssertTrue(bridge.replacedWholeText)
        assertMatchesFullProjection(session, bridge, "theme and document", requiresSplice: false)

        bridge.resetReplacements()
        session.replaceDocument(MarkdownDocument(markdown: ProjectionComparison.richMarkdown))
        assertMatchesFullProjection(session, bridge, "document only")
    }

    // MARK: - Helpers

    private func makeSession() -> (MarkdownEditingSession, SpliceRecordingBridge) {
        let session = MarkdownEditingSession(document: ProjectionComparison.richDocument, theme: .docC)
        let bridge = SpliceRecordingBridge()
        session.attach(to: bridge)
        return (session, bridge)
    }

    /// Delivers an edit the way the platform text views do.
    private func edit(
        _ session: MarkdownEditingSession,
        _ bridge: SpliceRecordingBridge,
        _ range: NSRange,
        _ replacement: String
    ) {
        bridge.markdownSelectedRanges = [range]
        session.selectionDidChange()
        guard session.shouldReplaceCharacters(in: range, with: replacement) else {
            return
        }
        bridge.replaceAttributedCharacters(
            in: range,
            with: NSAttributedString(string: replacement, attributes: bridge.markdownTypingAttributes)
        )
        bridge.markdownSelectedRanges = [NSRange(location: range.location + replacement.utf16.count, length: 0)]
        session.storageDidChange()
    }

    private func firstUnit(
        in session: MarkdownEditingSession,
        where matches: (MarkdownBlock) -> Bool
    ) throws -> ProjectionUnit {
        try XCTUnwrap(session.projection.index.units.first { unit in
            unit.path.rootBlockIndex.map { matches(session.document.blocks[$0]) } ?? false
        })
    }

    private func lastUnit(
        in session: MarkdownEditingSession,
        where matches: (MarkdownBlock) -> Bool
    ) throws -> ProjectionUnit {
        try XCTUnwrap(session.projection.index.units.last { unit in
            unit.path.rootBlockIndex.map { matches(session.document.blocks[$0]) } ?? false
        })
    }

    private func attachments<Attachment: NSTextAttachment>(
        in text: NSAttributedString,
        ofType _: Attachment.Type
    ) -> [Attachment] {
        var result: [Attachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? Attachment {
                result.append(attachment)
            }
        }
        return result
    }

    private func assertMatchesFullProjection(
        _ session: MarkdownEditingSession,
        _ bridge: SpliceRecordingBridge,
        _ message: String,
        requiresSplice: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Storage substitutes fonts for characters such as emoji, so compare with stored text.
        var expected = MarkdownProjectionBuilder().build(document: session.document, theme: session.theme)
        let storage = NSTextStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: expected.attributedString)
        expected.attributedString = storage
        ProjectionComparison.assertEquivalent(
            bridge.markdownTextStorage,
            session.projection.index,
            to: expected,
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(session.projection.string, bridge.markdownTextStorage.string, message, file: file, line: line)
        XCTAssertEqual(session.projection.source, session.document.markdown, message, file: file, line: line)
        if requiresSplice {
            XCTAssertFalse(bridge.replacedWholeText, "\(message) replaced all text", file: file, line: line)
        }
    }
}

@MainActor private final class SpliceRecordingBridge: TextViewBridge {
    let markdownTextStorage = NSTextStorage()
    var markdownSelectedRanges = [NSRange(location: 0, length: 0)]
    var markdownTypingAttributes: [NSAttributedString.Key: Any] = [:]
    var markdownHasMarkedText = false
    let undoManager: UndoManager? = UndoManager()
    /// Ranges replaced since the last reset.
    private(set) var replacements: [NSRange] = []
    /// Whether a replacement since the last reset covered the whole non-empty text.
    private(set) var replacedWholeText = false

    func resetReplacements() {
        replacements = []
        replacedWholeText = false
    }

    func replaceAttributedCharacters(in range: NSRange, with replacement: NSAttributedString) {
        replacements.append(range)
        if range.location == 0, range.length == markdownTextStorage.length, range.length > 0 {
            replacedWholeText = true
        }
        markdownTextStorage.replaceCharacters(in: range, with: replacement)
    }
}
