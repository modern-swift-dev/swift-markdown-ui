import Foundation
@testable import MarkdownUIEditor
import XCTest

@MainActor final class MarkdownProjectionTests: XCTestCase {
    func testPlainTextMappingRoundTripsUTF16() {
        let text = "ASCII e\u{301} 👩‍👩‍👧‍👦 אבג"
        let projection = MarkdownProjectionBuilder().build(
            document: MarkdownDocument(blocks: [.paragraph([.text(text)])])
        )

        XCTAssertEqual(projection.string, text + "\n")
        XCTAssertEqual(projection.source, text + "\n")
        for offset in 0 ... (projection.string as NSString).length {
            let anchor = projection.index.sourceAnchor(atProjectionUTF16Offset: offset)
            XCTAssertEqual(anchor?.utf16Offset, offset, "projection UTF-16 offset \(offset)")
            XCTAssertEqual(anchor.flatMap(projection.index.projectionUTF16Offset), offset)
        }
    }

    func testSourceIndexBuildSkipsNativeTextAndPreservesMappings() {
        let document = MarkdownDocument(markdown: "**text** ![alt](image.png)\n\n> | Header |\n> | --- |\n> | cell |\n\n- [x] task")
        let native = MarkdownProjectionBuilder().build(document: document)
        let metadata = MarkdownProjectionBuilder().build(document: document, output: .sourceIndex)
        XCTAssertEqual(metadata.attributedString.length, 0)
        XCTAssertEqual(metadata.index.projectionUTF16Length, native.index.projectionUTF16Length)
        XCTAssertEqual(metadata.index.units.map(\.segments), native.index.units.map(\.segments))
        XCTAssertEqual(metadata.source, native.source)
    }

    func testLongPlainTextUsesOneMappingRun() {
        let value = String(repeating: "text e\u{301} 👩‍👩‍👧‍👦 ", count: 1000)
        let projection = MarkdownProjectionBuilder().build(document: MarkdownDocument(blocks: [.paragraph([.text(value)])]))
        let segments = projection.index.units.flatMap(\.segments)
        XCTAssertEqual(segments.count, 2, "One text run and the terminating newline")
        XCTAssertEqual(segments.first?.projectionRange.length, value.utf16.count)
        XCTAssertEqual(segments.first?.sourceRange.length, value.utf16.count)
        XCTAssertEqual(projection.string, value + "\n")
    }

    func testManyLeavesKeepIndependentMappingSegments() {
        let values = (0 ..< 1000).map { "Paragraph \($0) 😀" }
        let document = MarkdownDocument(blocks: values.map { .paragraph([.text($0)]) })
        let projection = MarkdownProjectionBuilder().build(document: document)
        let units = projection.index.units
        XCTAssertEqual(units.count, values.count)
        var offset = 0
        for (unit, value) in zip(units, values) {
            let length = value.utf16.count
            XCTAssertEqual(unit.segments.count, 2)
            XCTAssertEqual(unit.segments.first?.projectionRange, ProjectionUTF16Range(location: offset, length: length))
            XCTAssertEqual(unit.segments.last?.sourceRange, SourceUTF16Range(location: offset + length, length: 1))
            XCTAssertEqual(projection.index.sourceAnchor(atProjectionUTF16Offset: offset)?.utf16Offset, offset)
            offset += length + 1
        }
        XCTAssertEqual(projection.index.projectionUTF16Length, offset)
        XCTAssertEqual(projection.index.sourceUTF16Length, offset)
    }

    func testBatchedTextPreservesEscapeAffinitiesAndUTF16Boundaries() {
        let projection = MarkdownProjectionBuilder().build(document: MarkdownDocument(blocks: [.paragraph([.text("ab😀*cd")])]))
        XCTAssertEqual(projection.string, "ab😀*cd\n")
        XCTAssertEqual(projection.source, "ab😀\\*cd\n")
        XCTAssertEqual(projection.index.units[0].segments.count, 4)
        for offset in 0 ... 8 {
            XCTAssertEqual(
                projection.index.sourceAnchor(atProjectionUTF16Offset: offset, affinity: .downstream)?.utf16Offset,
                offset + (offset >= 4 ? 1 : 0)
            )
            XCTAssertEqual(
                projection.index.sourceAnchor(atProjectionUTF16Offset: offset, affinity: .upstream)?.utf16Offset,
                offset + (offset > 4 ? 1 : 0)
            )
        }
        for offset in 0 ... 9 {
            for affinity in [SourceAnchor.Affinity.upstream, .downstream] {
                XCTAssertEqual(
                    projection.index.projectionUTF16Offset(for: SourceAnchor(utf16Offset: offset, affinity: affinity)),
                    offset - (offset >= 5 ? 1 : 0)
                )
            }
        }
    }

    func testBatchedTextKeepsLiteralObjectMappingSeparate() {
        let projection = MarkdownProjectionBuilder().build(document: MarkdownDocument(blocks: [.paragraph([.text("before\u{fffc}after")])]))
        XCTAssertEqual(projection.index.units[0].segments.map(\.kind), [.text, .objectReplacement, .text, .text])
    }

    func testInactiveRichInlineHidesDelimiters() {
        let document = MarkdownDocument(blocks: [
            .paragraph([
                .strong([.text("bold")]),
                .text(" and "),
                .emphasis([.text("italic")]),
                .text(" "),
                .strikethrough([.text("strike")]),
                .text(" "),
                .code("code"),
                .text(" "),
                .link(destination: "/target", title: "title", children: [.text("link")])
            ])
        ])
        let projection = MarkdownProjectionBuilder().build(document: document)

        XCTAssertEqual(projection.string, "bold and italic strike code link\n")
        XCTAssertEqual(projection.source, "**bold** and *italic* ~~strike~~ `code` [link](/target \"title\")\n")

        let boldProjectionOffset = (projection.string as NSString).range(of: "bold").location + 2
        let boldSourceOffset = (projection.source as NSString).range(of: "bold").location + 2
        let anchor = projection.index.sourceAnchor(atProjectionUTF16Offset: boldProjectionOffset)
        XCTAssertEqual(anchor?.utf16Offset, boldSourceOffset)
        XCTAssertEqual(anchor.flatMap(projection.index.projectionUTF16Offset), boldProjectionOffset)
    }

    func testTextPunctuationIsEscapedWithoutChangingProjection() {
        let projection = MarkdownProjectionBuilder().build(
            document: MarkdownDocument(blocks: [.paragraph([.text("# [literal] *text*")])])
        )

        XCTAssertEqual(projection.string, "# [literal] *text*\n")
        XCTAssertEqual(projection.source, "\\# \\[literal\\] \\*text\\*\n")
        XCTAssertEqual(MarkdownDocument(markdown: projection.source).blocks, [
            .paragraph([.text("# [literal] *text*")])
        ])
    }

    func testProjectionCarriesSemanticAttributesWithoutVisibleDelimiters() throws {
        let projection = MarkdownProjectionBuilder().build(
            document: MarkdownDocument(blocks: [
                .paragraph([.strong([.emphasis([.text("bold")])])])
            ])
        )

        XCTAssertEqual(projection.string, "bold\n")
        XCTAssertEqual(projection.source, "***bold***\n")
        let attributes = projection.attributedString.attributes(at: 1, effectiveRange: nil)
        XCTAssertTrue(try XCTUnwrap(attributes[.markdownEditorStrong] as? Bool))
        XCTAssertTrue(try XCTUnwrap(attributes[.markdownEditorEmphasis] as? Bool))
    }

    func testNestedQuoteAndListPrefixesAreSerializedAndHidden() {
        let document = MarkdownDocument(blocks: [
            .blockquote([
                .list(
                    MarkdownList(
                        kind: .unordered,
                        isTight: true,
                        items: [MarkdownListItem(blocks: [.paragraph([.text("value")])])]
                    )
                )
            ])
        ])
        let inactive = MarkdownProjectionBuilder().build(document: document)
        XCTAssertEqual(inactive.source, document.markdown)
        XCTAssertEqual(inactive.string, "value\n")

        XCTAssertFalse(inactive.string.contains(">"))
        XCTAssertFalse(inactive.string.contains("- "))
        let paragraphStyle = inactive.attributedString.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(paragraphStyle?.textLists.count, 1)
        XCTAssertGreaterThan(paragraphStyle?.headIndent ?? 0, 0)
    }

    func testOrderedListParagraphStylesShareListAndStartingNumber() throws {
        let document = MarkdownDocument(blocks: [
            .list(MarkdownList(
                kind: .ordered(start: 4),
                isTight: true,
                items: [
                    MarkdownListItem(blocks: [.paragraph([.text("first")])]),
                    MarkdownListItem(blocks: [.paragraph([.text("second")])]),
                    MarkdownListItem(blocks: [.paragraph([.text("third")])])
                ]
            ))
        ])
        let projection = MarkdownProjectionBuilder().build(document: document)

        let textLists = projection.index.units.compactMap { unit -> NSTextList? in
            let style = projection.attributedString.attribute(
                .paragraphStyle,
                at: unit.projectionRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            return style?.textLists.first
        }
        let firstTextList = try XCTUnwrap(textLists.first)

        XCTAssertEqual(textLists.map(\.startingItemNumber), [4, 4, 4])
        XCTAssertTrue(textLists.allSatisfy { $0 === firstTextList })
        XCTAssertEqual((1 ... 3).map { firstTextList.marker(forItemNumber: $0) }, ["1.", "2.", "3."])
        XCTAssertEqual(firstTextList.marker(forItemNumber: 4), "4.")
    }

    func testCheckedTaskStrikethroughIsPresentationOnly() {
        let document = MarkdownDocument(markdown: "- [x] done **bold** `code`\n- [ ] pending ~~deleted~~")
        let projection = MarkdownProjectionBuilder().build(document: document)
        for text in ["done", "bold", "code", "deleted"] {
            let range = (projection.string as NSString).range(of: text)
            XCTAssertEqual(projection.attributedString.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        }
        let pending = (projection.string as NSString).range(of: "pending")
        XCTAssertNil(projection.attributedString.attribute(.strikethroughStyle, at: pending.location, effectiveRange: nil))
        let done = (projection.string as NSString).range(of: "done")
        XCTAssertEqual(MarkdownAttributedInlineDecoder.decode(projection.attributedString.attributedSubstring(from: done)), [.text("done")])
        XCTAssertFalse(projection.source.contains("~~done"))
    }

    func testAttributedNormalizationPreservesStylesAroundCodeAndDropsNativeOnlyStyles() {
        let attributes: [NSAttributedString.Key: Any] = [
            .markdownEditorCode: true,
            .markdownEditorStrong: true,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: "red"
        ]
        let attributed = NSAttributedString(string: "code", attributes: attributes)

        XCTAssertEqual(MarkdownAttributedInlineDecoder.decode(attributed), [.strong([.code("code")])])
    }

    func testCodeAndHTMLKeepEnclosingLinksAndStylesWhenDecodingEditedParagraph() {
        for source in [
            "[`code`](/target) tail",
            "**`code`** tail",
            "*`code`* tail",
            "~~`code`~~ tail",
            "[**`code`**](/target \"Title\") tail",
            "[<kbd>HTML</kbd>](/target) tail"
        ] {
            let document = MarkdownDocument(markdown: source)
            let projection = MarkdownProjectionBuilder().build(document: document)
            let content = NSMutableAttributedString(attributedString: projection.attributedString.attributedSubstring(
                from: NSRange(location: 0, length: projection.attributedString.length - 1)
            ))
            content.append(NSAttributedString(string: "!"))
            let decoded = MarkdownDocument(blocks: [.paragraph(MarkdownAttributedInlineDecoder.decode(content))])
            XCTAssertEqual(decoded, MarkdownDocument(markdown: source + "!"), source)
            XCTAssertEqual(MarkdownDocument(markdown: decoded.markdown), decoded, source)
        }
    }

    func testHardLineBreakSurvivesRichProjectionDecoding() throws {
        let document = MarkdownDocument(blocks: [
            .paragraph([.text("before"), .lineBreak, .text("after")])
        ])
        let projection = MarkdownProjectionBuilder().build(document: document)
        let lineBreakOffset = (projection.string as NSString).range(of: "\n").location

        XCTAssertTrue(try XCTUnwrap(
            projection.attributedString.attribute(
                .markdownEditorHardBreak,
                at: lineBreakOffset,
                effectiveRange: nil
            ) as? Bool
        ))
        XCTAssertEqual(
            MarkdownAttributedInlineDecoder.decode(
                projection.attributedString.attributedSubstring(
                    from: NSRange(location: 0, length: projection.string.utf16.count - 1)
                )
            ),
            [.text("before"), .lineBreak, .text("after")]
        )
    }

    func testEveryBlockAndInlineKindProjects() {
        let inlineContent: [MarkdownInline] = [
            .text("text"), .softBreak, .lineBreak, .code("code"), .html("<b>x</b>"),
            .emphasis([.text("em")]), .strong([.text("strong")]),
            .strikethrough([.text("strike")]),
            .link(destination: "/link", title: nil, children: [.text("link")]),
            .image(source: "/image.png", title: "image", children: [.text("alt")])
        ]
        let table = MarkdownTable(
            alignments: [.left, .right],
            header: MarkdownTableRow(cells: [
                MarkdownTableCell(content: [.text("A")]),
                MarkdownTableCell(content: [.text("B")])
            ]),
            rows: [MarkdownTableRow(cells: [
                MarkdownTableCell(content: [.text("1")]),
                MarkdownTableCell(content: [.text("2")])
            ])]
        )
        let document = MarkdownDocument(blocks: [
            .blockquote([.paragraph([.text("quote")])]),
            .list(MarkdownList(
                kind: .ordered(start: 3),
                isTight: false,
                items: [MarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("task")])])]
            )),
            .codeBlock(info: "swift", content: "let x = 1"),
            .html("<div>block</div>"),
            .paragraph(inlineContent),
            .heading(level: .three, content: [.text("Heading")]),
            .table(table),
            .thematicBreak
        ])

        let projection = MarkdownProjectionBuilder().build(document: document)
        XCTAssertEqual(projection.index.units.count, 8)
        XCTAssertEqual(
            projection.index.units.map(\.kind),
            [.paragraph, .paragraph, .codeBlock, .htmlBlock, .paragraph, .heading(.three), .table, .thematicBreak]
        )
        XCTAssertTrue(projection.string.contains("quote"))
        XCTAssertTrue(projection.string.contains("\u{fffc}"))
        XCTAssertEqual(projection.source, document.markdown)
        XCTAssertTrue(projection.source.contains("let x = 1"))
    }

    func testImagesTablesAndThematicBreaksUseOneUTF16ObjectUnit() {
        let table = MarkdownTable(
            alignments: [.none],
            header: MarkdownTableRow(cells: [MarkdownTableCell(content: [.text("H")])]),
            rows: []
        )
        let document = MarkdownDocument(blocks: [
            .paragraph([.image(source: "/image", title: nil, children: [.text("alt")])]),
            .table(table),
            .thematicBreak
        ])
        let projection = MarkdownProjectionBuilder().build(document: document)
        let objects = projection.index.units.flatMap(\.segments).filter { $0.kind == .objectReplacement }

        XCTAssertEqual(objects.count, 3)
        XCTAssertTrue(objects.allSatisfy { $0.projectionRange.length == 1 })
        for object in objects {
            XCTAssertEqual((projection.string as NSString).substring(with: object.projectionRange.nsRange), "\u{fffc}")
        }

        let tableAttachment = projection.attributedString.attribute(
            .attachment,
            at: objects[1].projectionRange.location,
            effectiveRange: nil
        )
        let imageAttachment = projection.attributedString.attribute(
            .attachment,
            at: objects[0].projectionRange.location,
            effectiveRange: nil
        )
        XCTAssertTrue(imageAttachment is MarkdownImageAttachment)
        XCTAssertTrue(tableAttachment is MarkdownTableAttachment)
        XCTAssertEqual(
            projection.attributedString.attribute(
                .markdownEditorObjectKind,
                at: objects[0].projectionRange.location,
                effectiveRange: nil
            ) as? String,
            "image"
        )
    }

    func testApplyReplacementShiftsLaterUnits() throws {
        let projection = MarkdownProjectionBuilder().build(
            document: MarkdownDocument(blocks: [
                .paragraph([.text("one")]),
                .paragraph([.text("two")])
            ])
        )
        var index = projection.index
        let originalSecond = try XCTUnwrap(index.units.last)

        index.applyReplacement(
            projectionRange: ProjectionUTF16Range(location: 1, length: 1),
            projectionReplacementUTF16Length: 4,
            sourceRange: SourceUTF16Range(location: 1, length: 1),
            sourceReplacementUTF16Length: 4
        )

        XCTAssertEqual(index.units.last?.projectionRange.location, originalSecond.projectionRange.location + 3)
        XCTAssertEqual(index.units.last?.sourceRange.location, originalSecond.sourceRange.location + 3)
        XCTAssertEqual(index.projectionUTF16Length, (projection.string as NSString).length + 3)
        XCTAssertEqual(index.sourceUTF16Length, projection.index.sourceUTF16Length + 3)
    }

    func testInsertionAtUnitBoundaryShiftsFollowingUnit() throws {
        let projection = MarkdownProjectionBuilder().build(
            document: MarkdownDocument(blocks: [
                .paragraph([.text("one")]),
                .paragraph([.text("two")])
            ])
        )
        var index = projection.index
        let second = try XCTUnwrap(index.units.last)

        index.applyReplacement(
            projectionRange: ProjectionUTF16Range(location: second.projectionRange.location, length: 0),
            projectionReplacementUTF16Length: 2,
            sourceRange: SourceUTF16Range(location: second.sourceRange.location, length: 0),
            sourceReplacementUTF16Length: 2
        )

        XCTAssertEqual(index.units.last?.projectionRange.location, second.projectionRange.location + 2)
        XCTAssertEqual(index.units.last?.sourceRange.location, second.sourceRange.location + 2)
    }

    func testReplaceFirstUnitWithPositiveDeltas() throws {
        try assertUnitReplacement(
            at: 0,
            projectionLengthChange: 3,
            sourceLengthChange: 5
        )
    }

    func testReplaceMiddleUnitWithNegativeDeltas() throws {
        try assertUnitReplacement(
            at: 2,
            projectionLengthChange: -2,
            sourceLengthChange: -1
        )
    }

    func testReplaceLastUnitWithZeroDeltas() throws {
        try assertUnitReplacement(
            at: 4,
            projectionLengthChange: 0,
            sourceLengthChange: 0
        )
    }

    func testRepeatedReplacementKeepsDeltasRelativeToFullBuild() {
        let projection = makeReplacementProjection()
        let originalUnits = projection.index.units
        let originalProjectionLength = projection.index.projectionUTF16Length
        let originalSourceLength = projection.index.sourceUTF16Length
        let activeUnit = originalUnits[2]
        var index = projection.index

        XCTAssertTrue(index.replaceUnit(
            at: activeUnit.path,
            projectionLength: activeUnit.projectionRange.length + 7,
            sourceLength: activeUnit.sourceRange.length + 5
        ))
        XCTAssertTrue(index.replaceUnit(
            at: activeUnit.path,
            projectionLength: activeUnit.projectionRange.length - 2,
            sourceLength: activeUnit.sourceRange.length - 1
        ))

        XCTAssertEqual(index.projectionUTF16Length, originalProjectionLength - 2)
        XCTAssertEqual(index.sourceUTF16Length, originalSourceLength - 1)
        XCTAssertEqual(
            index.units[3].projectionRange.location,
            originalUnits[3].projectionRange.location - 2
        )
        XCTAssertEqual(
            index.units[3].sourceRange.location,
            originalUnits[3].sourceRange.location - 1
        )
    }

    func testVisibleUnitStartsApplyDeltasWithoutReturningMappingSegments() {
        var index = makeReplacementProjection().index
        let originalUnits = index.units
        let first = originalUnits[0]
        XCTAssertTrue(index.replaceUnit(
            at: first.path,
            projectionLength: first.projectionRange.length + 7,
            sourceLength: first.sourceRange.length + 11
        ))
        let visibleStart = originalUnits[2].projectionRange.location + 7
        let visibleEnd = originalUnits[4].projectionRange.location + 7
        XCTAssertEqual(
            index.unitStartOffsets(in: ProjectionUTF16Range(
                location: visibleStart, length: visibleEnd - visibleStart
            )),
            [visibleStart, originalUnits[3].projectionRange.location + 7]
        )
        XCTAssertEqual(index.unitStartOffsets(in: ProjectionUTF16Range(location: 0, length: 0)), [])
        XCTAssertEqual(index.unitStartOffsets(in: ProjectionUTF16Range(
            location: index.projectionUTF16Length, length: 10
        )), [])
        XCTAssertEqual(index.unitStartOffsets(in: ProjectionUTF16Range(
            location: visibleStart + 1, length: 1
        )), [])
    }

    func testReplaceFirstUnitPerformance() throws {
        try measureUnitReplacement(at: 0)
    }

    func testReplaceMiddleUnitPerformance() throws {
        try measureUnitReplacement(at: Self.performanceUnitCount / 2)
    }

    func testReplaceLastUnitPerformance() throws {
        try measureUnitReplacement(at: Self.performanceUnitCount - 1)
    }

    func testInvalidAnchorsReturnNil() {
        let projection = MarkdownProjectionBuilder().build(
            document: MarkdownDocument(blocks: [.paragraph([.text("text")])])
        )

        XCTAssertNil(projection.index.sourceAnchor(atProjectionUTF16Offset: -1))
        XCTAssertNil(projection.index.sourceAnchor(atProjectionUTF16Offset: 100))
        XCTAssertNil(projection.index.projectionUTF16Offset(for: SourceAnchor(utf16Offset: -1)))
        XCTAssertNil(projection.index.projectionUTF16Offset(for: SourceAnchor(utf16Offset: 100)))
    }

    private static let performanceUnitCount = 5000

    private func assertUnitReplacement(
        at replacedIndex: Int,
        projectionLengthChange: Int,
        sourceLengthChange: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let projection = makeReplacementProjection()
        let originalUnits = projection.index.units
        let originalProjectionLength = projection.index.projectionUTF16Length
        let originalSourceLength = projection.index.sourceUTF16Length
        let original = originalUnits[replacedIndex]
        let replacementProjectionLength = original.projectionRange.length + projectionLengthChange
        let replacementSourceLength = original.sourceRange.length + sourceLengthChange
        var expectedUnits = originalUnits
        let expectedProjectionRange = ProjectionUTF16Range(
            location: original.projectionRange.location,
            length: replacementProjectionLength
        )
        let expectedSourceRange = SourceUTF16Range(
            location: original.sourceRange.location,
            length: replacementSourceLength
        )
        expectedUnits[replacedIndex] = ProjectionUnit(
            id: original.id,
            path: original.path,
            kind: original.kind,
            projectionRange: expectedProjectionRange,
            sourceRange: expectedSourceRange,
            segments: [OffsetMapSegment(
                projectionRange: expectedProjectionRange,
                sourceRange: expectedSourceRange,
                kind: .text
            )]
        )
        if replacedIndex + 1 < expectedUnits.count {
            for unitIndex in (replacedIndex + 1) ..< expectedUnits.count {
                expectedUnits[unitIndex].projectionRange.location += projectionLengthChange
                expectedUnits[unitIndex].sourceRange.location += sourceLengthChange
                for segmentIndex in expectedUnits[unitIndex].segments.indices {
                    expectedUnits[unitIndex].segments[segmentIndex].projectionRange.location += projectionLengthChange
                    expectedUnits[unitIndex].segments[segmentIndex].sourceRange.location += sourceLengthChange
                }
            }
        }
        let expectedIndex = ProjectionIndex(
            units: expectedUnits,
            projectionUTF16Length: originalProjectionLength + projectionLengthChange,
            sourceUTF16Length: originalSourceLength + sourceLengthChange
        )
        var index = projection.index

        XCTAssertTrue(
            index.replaceUnit(
                at: original.path,
                projectionLength: replacementProjectionLength,
                sourceLength: replacementSourceLength
            ),
            file: file,
            line: line
        )

        XCTAssertEqual(index.projectionUTF16Length, expectedIndex.projectionUTF16Length, file: file, line: line)
        XCTAssertEqual(index.sourceUTF16Length, expectedIndex.sourceUTF16Length, file: file, line: line)
        XCTAssertEqual(index.units, expectedIndex.units, file: file, line: line)

        for unit in expectedUnits {
            XCTAssertEqual(index.unit(at: unit.path), unit, file: file, line: line)
            XCTAssertEqual(
                index.sourceRange(forProjectionRange: unit.projectionRange),
                expectedIndex.sourceRange(forProjectionRange: unit.projectionRange),
                file: file,
                line: line
            )
            XCTAssertEqual(
                index.sourceRange(
                    forProjectionRange: unit.projectionRange,
                    includingBoundaryMarkup: true
                ),
                expectedIndex.sourceRange(
                    forProjectionRange: unit.projectionRange,
                    includingBoundaryMarkup: true
                ),
                file: file,
                line: line
            )
        }

        let affinities: [SourceAnchor.Affinity] = [.upstream, .downstream]
        for offset in 0 ... expectedIndex.projectionUTF16Length {
            XCTAssertEqual(
                index.unit(atProjectionUTF16Offset: offset),
                expectedIndex.unit(atProjectionUTF16Offset: offset),
                file: file,
                line: line
            )
            for affinity in affinities {
                XCTAssertEqual(
                    index.sourceAnchor(atProjectionUTF16Offset: offset, affinity: affinity),
                    expectedIndex.sourceAnchor(atProjectionUTF16Offset: offset, affinity: affinity),
                    file: file,
                    line: line
                )
            }
        }
        for offset in 0 ... expectedIndex.sourceUTF16Length {
            for affinity in affinities {
                let anchor = SourceAnchor(utf16Offset: offset, affinity: affinity)
                XCTAssertEqual(
                    index.projectionUTF16Offset(for: anchor),
                    expectedIndex.projectionUTF16Offset(for: anchor),
                    file: file,
                    line: line
                )
            }
        }
    }

    private func makeReplacementProjection() -> DocumentProjection {
        MarkdownProjectionBuilder().build(
            document: MarkdownDocument(blocks: [
                .paragraph([.strong([.text("first")]), .text(" tail")]),
                .heading(level: .two, content: [.emphasis([.text("second")])]),
                .paragraph([
                    .text("before "),
                    .link(destination: "/target", title: "title", children: [.text("middle")]),
                    .text(" after")
                ]),
                .paragraph([.strikethrough([.text("fourth")]), .text(" tail")]),
                .codeBlock(info: "swift", content: "let value = 5")
            ])
        )
    }

    private func measureUnitReplacement(at unitIndex: Int) throws {
        let document = MarkdownDocument(
            blocks: (0 ..< Self.performanceUnitCount).map { index in
                .paragraph([.text("unit \(index)")])
            }
        )
        var index = MarkdownProjectionBuilder().build(document: document).index
        let unit = index.units[unitIndex]
        let projectionLength = unit.projectionRange.length
        let sourceLength = unit.sourceRange.length

        measure {
            for iteration in 0 ..< 10000 {
                let lengthChange = iteration.isMultiple(of: 2) ? 1 : 0
                _ = index.replaceUnit(
                    at: unit.path,
                    projectionLength: projectionLength + lengthChange,
                    sourceLength: sourceLength + lengthChange
                )
            }
        }

        XCTAssertEqual(index.unit(at: unit.path)?.projectionRange.length, projectionLength)
        XCTAssertEqual(index.unit(at: unit.path)?.sourceRange.length, sourceLength)
    }
}
