@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class FlowLayoutTests: XCTestCase {
    private func swatch(_ width: CGFloat, _ height: CGFloat, _ color: Color = .pureRed) -> some View {
        color.frame(width: width, height: height)
    }

    func testItemsStayOnOneRowWhenTheyFitAndAreSeparatedByHorizontalSpacing() throws {
        let layout = FlowLayout(horizontalSpacing: 7, verticalSpacing: 3) {
            swatch(20, 10, .pureRed)
            swatch(30, 10, .pureGreen)
            swatch(10, 10, .pureBlue)
        }
        let image = try RenderedImage.render(layout, width: 200)
        XCTAssertEqual(RenderedImage.size(of: image), CGSize(width: 20 + 7 + 30 + 7 + 10, height: 10))
        XCTAssertEqual(try RenderedImage.pixel(in: image, x: 10, y: 5), .pureRed)
        XCTAssertEqual(try RenderedImage.pixel(in: image, x: 23, y: 5), .clear, "Gap after the first item")
        XCTAssertEqual(try RenderedImage.pixel(in: image, x: 35, y: 5), .pureGreen)
        XCTAssertEqual(try RenderedImage.pixel(in: image, x: 61, y: 5), .clear, "Gap after the second item")
        XCTAssertEqual(try RenderedImage.pixel(in: image, x: 70, y: 5), .pureBlue)
    }

    func testItemsWrapToANewRowSeparatedByVerticalSpacing() throws {
        let layout = FlowLayout(horizontalSpacing: 5, verticalSpacing: 9) {
            swatch(20, 10, .pureRed)
            swatch(20, 10, .pureGreen)
            swatch(20, 10, .pureBlue)
        }
        // Two items plus their spacing take 45pt; the third needs 70pt.
        let wrapped = try RenderedImage.render(layout, width: 60)
        XCTAssertEqual(RenderedImage.size(of: wrapped), CGSize(width: 45, height: 10 + 9 + 10))
        XCTAssertEqual(try RenderedImage.pixel(in: wrapped, x: 10, y: 5), .pureRed)
        XCTAssertEqual(try RenderedImage.pixel(in: wrapped, x: 35, y: 5), .pureGreen)
        XCTAssertEqual(try RenderedImage.pixel(in: wrapped, x: 10, y: 15), .clear, "Vertical gap")
        XCTAssertEqual(try RenderedImage.pixel(in: wrapped, x: 10, y: 25), .pureBlue)
        XCTAssertEqual(try RenderedImage.pixel(in: wrapped, x: 35, y: 25), .clear)

        // At exactly the width of one row's content all three items still wrap after the second.
        let exact = try RenderedImage.render(layout, width: 45)
        XCTAssertEqual(RenderedImage.size(of: exact), CGSize(width: 45, height: 29))

        // One point narrower than two items pushes each item onto its own row.
        let narrow = try RenderedImage.render(layout, width: 44)
        XCTAssertEqual(RenderedImage.size(of: narrow), CGSize(width: 20, height: 10 + 9 + 10 + 9 + 10))
    }

    func testAnItemWiderThanTheProposalGetsItsOwnRow() throws {
        let layout = FlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
            swatch(10, 10, .pureRed)
            swatch(50, 10, .pureGreen)
            swatch(10, 10, .pureBlue)
        }
        let image = try RenderedImage.render(layout, width: 30)
        XCTAssertEqual(RenderedImage.size(of: image).height, 10 + 4 + 10 + 4 + 10)
        XCTAssertEqual(try RenderedImage.pixel(in: image, x: 5, y: 5), .pureRed)
        XCTAssertEqual(try RenderedImage.pixel(in: image, x: 25, y: 19), .pureGreen)
        XCTAssertEqual(try RenderedImage.pixel(in: image, x: 5, y: 33), .pureBlue)
    }

    func testMixedHeightsShareARowAndAlignToItsBottom() throws {
        let layout = FlowLayout(horizontalSpacing: 4, verticalSpacing: 6) {
            swatch(20, 10, .pureRed)
            swatch(20, 30, .pureGreen)
            swatch(20, 20, .pureBlue)
        }
        let image = try RenderedImage.render(layout, width: 200)
        XCTAssertEqual(RenderedImage.size(of: image), CGSize(width: 20 * 3 + 4 * 2, height: 30))
        let red = try RenderedImage.column(10, in: image)
        let green = try RenderedImage.column(34, in: image)
        let blue = try RenderedImage.column(58, in: image)
        XCTAssertEqual(red.filter { $0 == .pureRed }.count, 10)
        XCTAssertEqual(red.last, .pureRed)
        XCTAssertEqual(red[19], .clear)
        XCTAssertEqual(green.filter { $0 == .pureGreen }.count, 30)
        XCTAssertEqual(blue.filter { $0 == .pureBlue }.count, 20)
        XCTAssertEqual(blue.last, .pureBlue)
        XCTAssertEqual(blue[9], .clear)
    }

    func testRowHeightIsTheTallestItemAndRowsStack() throws {
        let layout = FlowLayout(horizontalSpacing: 2, verticalSpacing: 5) {
            swatch(30, 10, .pureRed)
            swatch(30, 25, .pureGreen)
            swatch(30, 8, .pureBlue)
            swatch(30, 40, .pureRed)
        }
        // 70 fits two items (30 + 2 + 30), so rows are [10, 25] and [8, 40].
        let image = try RenderedImage.render(layout, width: 70)
        XCTAssertEqual(RenderedImage.size(of: image), CGSize(width: 62, height: 25 + 5 + 40))
    }

    func testChangingTheProposalRelayoutsInsteadOfReusingStaleRows() throws {
        let layout = FlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
            swatch(20, 10, .pureRed)
            swatch(20, 10, .pureGreen)
        }
        XCTAssertEqual(RenderedImage.size(of: try RenderedImage.render(layout, width: 100)).height, 10)
        XCTAssertEqual(RenderedImage.size(of: try RenderedImage.render(layout, width: 30)).height, 25)
        XCTAssertEqual(RenderedImage.size(of: try RenderedImage.render(layout, width: 100)).height, 10)
    }
}
