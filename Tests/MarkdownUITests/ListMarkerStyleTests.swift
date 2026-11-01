@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class ListMarkerStyleTests: XCTestCase {
    private struct Marker: Hashable {
        let level: Int
        let number: Int
    }

    private final class Recorder: @unchecked Sendable {
        var markers: Set<Marker> = []

        func tag<Content: View>(_ configuration: ListMarkerConfiguration, _ view: Content) -> Content {
            self.markers.insert(.init(level: configuration.listLevel, number: configuration.itemNumber))
            return view
        }
    }

    func testMarkerConfigurationReportsLevelAndItemNumber() throws {
        let recorder = Recorder()
        let style = BlockStyle<ListMarkerConfiguration> { configuration in
            recorder.tag(configuration, Text("*"))
        }
        _ = try RenderedImage.render(
            MarkdownView("3. a\n4. b\n   1. c\n   2. d\n5. e").markdownNumberedListMarker(style), width: 200
        )
        XCTAssertEqual(recorder.markers, [
            .init(level: 1, number: 3), .init(level: 1, number: 4), .init(level: 1, number: 5),
            .init(level: 2, number: 1), .init(level: 2, number: 2)
        ])
    }

    func testUpperRomanMarkersUseUppercaseNumeralsWithTheDecimalLayout() throws {
        let numerals = ["I.", "II.", "III.", "IV."]
        let expected = BlockStyle<ListMarkerConfiguration> { configuration in
            Text(numerals[configuration.itemNumber - 1]).relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        XCTAssertTrue(try RenderedImage.rendersIdentically(
            MarkdownView(self.numberedList).markdownNumberedListMarker(.upperRoman),
            MarkdownView(self.numberedList).markdownNumberedListMarker(expected), width: 200
        ))
        XCTAssertFalse(try RenderedImage.rendersIdentically(
            MarkdownView(self.numberedList).markdownNumberedListMarker(.upperRoman),
            MarkdownView(self.numberedList).markdownNumberedListMarker(.lowerRoman), width: 200
        ))
    }

    func testLowerRomanMarkersUseLowercaseNumeralsAndHonorMinWidthAndAlignment() throws {
        let numerals = ["i.", "ii.", "iii.", "iv."]
        let expected = BlockStyle<ListMarkerConfiguration> { configuration in
            Text(numerals[configuration.itemNumber - 1]).relativeFrame(minWidth: .em(3), alignment: .leading)
        }
        XCTAssertTrue(try RenderedImage.rendersIdentically(
            MarkdownView(self.numberedList).markdownNumberedListMarker(.lowerRoman(minWidth: .em(3), alignment: .leading)),
            MarkdownView(self.numberedList).markdownNumberedListMarker(expected), width: 200
        ))
        XCTAssertFalse(try RenderedImage.rendersIdentically(
            MarkdownView(self.numberedList).markdownNumberedListMarker(.lowerRoman(minWidth: .em(3), alignment: .leading)),
            MarkdownView(self.numberedList).markdownNumberedListMarker(.lowerRoman), width: 200
        ))
    }

    func testRomanMarkersContinueFromTheListStart() throws {
        let expected = BlockStyle<ListMarkerConfiguration> { configuration in
            Text(configuration.itemNumber == 9 ? "ix." : "x.").relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        XCTAssertTrue(try RenderedImage.rendersIdentically(
            MarkdownView("9. a\n10. b").markdownNumberedListMarker(.lowerRoman),
            MarkdownView("9. a\n10. b").markdownNumberedListMarker(expected), width: 200
        ))
    }

    func testDecimalMarkersMatchTheMinWidthAndAlignmentOverload() throws {
        XCTAssertTrue(try RenderedImage.rendersIdentically(
            MarkdownView(self.numberedList).markdownNumberedListMarker(.decimal),
            MarkdownView(self.numberedList)
                .markdownNumberedListMarker(.decimal(minWidth: .em(1.5), alignment: .trailing)), width: 200
        ))
        XCTAssertFalse(try RenderedImage.rendersIdentically(
            MarkdownView(self.numberedList).markdownNumberedListMarker(.decimal),
            MarkdownView(self.numberedList)
                .markdownNumberedListMarker(.decimal(minWidth: .em(1.5), alignment: .leading)), width: 200
        ))
    }

    func testBulletStylesAreDistinctAndDefaultOverloadsUseTheTrailingMinWidth() throws {
        let styles: [(String, BlockStyle<ListMarkerConfiguration>, BlockStyle<ListMarkerConfiguration>)] = [
            ("dash", .dash, .dash(minWidth: .em(1.5), alignment: .trailing)),
            ("disc", .disc, .disc(minWidth: .em(1.5), alignment: .trailing)),
            ("circle", .circle, .circle(minWidth: .em(1.5), alignment: .trailing)),
            ("square", .square, .square(minWidth: .em(1.5), alignment: .trailing))
        ]
        var bitmaps: [[UInt8]] = []
        for (name, style, explicit) in styles {
            XCTAssertTrue(try RenderedImage.rendersIdentically(
                MarkdownView(self.bulletedList).markdownBulletedListMarker(style),
                MarkdownView(self.bulletedList).markdownBulletedListMarker(explicit), width: 200
            ), name)
            bitmaps.append(try RenderedImage.bytes(of: RenderedImage.render(
                MarkdownView(self.bulletedList).markdownBulletedListMarker(style), width: 200
            )))
        }
        XCTAssertEqual(Set(bitmaps).count, styles.count, "Dash, disc, circle and square must look different")
    }

    func testDiscCircleSquareFollowsTheListLevelAndStaysOnSquareBeyondThree() throws {
        let nested = "- a\n  - b\n    - c\n      - d\n        - e"
        let expected = BlockStyle<ListMarkerConfiguration> { configuration in
            switch configuration.listLevel {
                case 1: BlockStyle<ListMarkerConfiguration>.disc.makeBody(configuration: configuration)
                case 2: BlockStyle<ListMarkerConfiguration>.circle.makeBody(configuration: configuration)
                default: BlockStyle<ListMarkerConfiguration>.square.makeBody(configuration: configuration)
            }
        }
        XCTAssertTrue(try RenderedImage.rendersIdentically(
            MarkdownView(nested).markdownBulletedListMarker(.discCircleSquare),
            MarkdownView(nested).markdownBulletedListMarker(expected), width: 300
        ))
        XCTAssertFalse(try RenderedImage.rendersIdentically(
            MarkdownView(nested).markdownBulletedListMarker(.discCircleSquare),
            MarkdownView(nested).markdownBulletedListMarker(.disc), width: 300
        ))
    }

    private let numberedList = "1. a\n2. b\n3. c\n4. d"
    private let bulletedList = "- a\n- b"
}
