@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class ThematicBreakAndSoftBreakTests: XCTestCase {
    func testThematicBreakViewRendersTheThemeBlockStyle() throws {
        let view = ThematicBreakView()
            .markdownBlockStyle(\.thematicBreak) { Color.pureRed.frame(height: 7) }
        let image = try RenderedImage.render(view, width: 120)
        XCTAssertEqual(RenderedImage.size(of: image), CGSize(width: 120, height: 7))
        XCTAssertEqual(try RenderedImage.pixel(in: image, x: 60, y: 3), .pureRed)
    }

    func testThematicBreakViewFollowsAThemeChange() throws {
        let tall = ThematicBreakView().markdownTheme(Theme().thematicBreak { Color.pureBlue.frame(height: 12) })
        let short = ThematicBreakView().markdownTheme(Theme().thematicBreak { Color.pureGreen.frame(height: 3) })
        let tallImage = try RenderedImage.render(tall, width: 40)
        let shortImage = try RenderedImage.render(short, width: 40)
        XCTAssertEqual(RenderedImage.size(of: tallImage).height, 12)
        XCTAssertEqual(try RenderedImage.pixel(in: tallImage, x: 20, y: 6), .pureBlue)
        XCTAssertEqual(RenderedImage.size(of: shortImage).height, 3)
        XCTAssertEqual(try RenderedImage.pixel(in: shortImage, x: 20, y: 1), .pureGreen)
    }

    func testMarkdownThematicBreakBetweenParagraphsUsesTheThemeBlockStyle() throws {
        let view = MarkdownView("above\n\n---\n\nbelow")
            .markdownBlockStyle(\.thematicBreak) { Color.pureRed.frame(height: 6) }
        let image = try RenderedImage.render(view, width: 120)
        let column = try RenderedImage.column(60, in: image)
        let redRows = column.indices.filter { column[$0] == .pureRed }
        XCTAssertEqual(redRows.count, 6, "Exactly the 6pt styled break must be red")
        XCTAssertEqual(redRows.last.map { $0 - redRows[0] }, 5, "The break must be a contiguous band")
    }

    func testSoftBreakModeDefaultsToSpace() throws {
        var captured: SoftBreak.Mode?
        let probe = SoftBreakModeProbe { captured = $0 }
        _ = try RenderedImage.render(probe, width: 10)
        XCTAssertEqual(captured, .space)
    }

    func testSoftBreakModeModifierSetsTheEnvironment() throws {
        for mode in [SoftBreak.Mode.lineBreak, .space] {
            var captured: SoftBreak.Mode?
            let probe = SoftBreakModeProbe { captured = $0 }.markdownSoftBreakMode(mode)
            _ = try RenderedImage.render(probe, width: 10)
            XCTAssertEqual(captured, mode)
        }
    }

    func testSoftBreakModeChangesHowSourceLinesAreLaidOut() throws {
        let source = "first\nsecond\nthird"
        let spaced = try RenderedImage.render(MarkdownView(source).markdownSoftBreakMode(.space), width: 300)
        let broken = try RenderedImage.render(MarkdownView(source).markdownSoftBreakMode(.lineBreak), width: 300)
        let single = try RenderedImage.render(MarkdownView("first").markdownSoftBreakMode(.lineBreak), width: 300)
        XCTAssertEqual(RenderedImage.size(of: spaced).height, RenderedImage.size(of: single).height)
        XCTAssertGreaterThan(RenderedImage.size(of: broken).height, RenderedImage.size(of: single).height * 2.5)
    }
}

private struct SoftBreakModeProbe: View {
    @Environment(\.softBreakMode) private var mode
    let record: @MainActor (SoftBreak.Mode) -> Void

    var body: some View {
        self.record(self.mode)
        return Color.clear.frame(width: 1, height: 1)
    }
}
