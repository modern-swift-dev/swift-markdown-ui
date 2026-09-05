#if os(iOS) || os(macOS)
@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class TableDecorationTests: XCTestCase {
    func testCachedExtentsMatchCellUnionsIncludingReversedColumnsAndGaps() {
        for reversed in [false, true] {
            var resolutions = 0
            let bounds = TableBounds(rowCount: 40, columnCount: 8, bounds: CGRect(x: 0, y: 0, width: 500, height: 1000)) { row, column in
                resolutions += 1
                let x = CGFloat(reversed ? 7 - column : column) * 60 + 2
                return CGRect(x: x, y: CGFloat(row) * 25 + 2, width: CGFloat(40 + column), height: CGFloat(15 + row % 4))
            }
            XCTAssertEqual(resolutions, 320)
            for _ in 0 ..< 10 {
                for row in 0 ..< bounds.rowCount {
                    let legacy = (0 ..< bounds.columnCount).map { bounds.bounds(forRow: row, column: $0) }.reduce(.null, CGRectUnion)
                    XCTAssertEqual(bounds.bounds(forRow: row), legacy)
                }
                for column in 0 ..< bounds.columnCount {
                    let legacy = (0 ..< bounds.rowCount).map { bounds.bounds(forRow: $0, column: column) }.reduce(.null, CGRectUnion)
                    XCTAssertEqual(bounds.bounds(forColumn: column), legacy)
                }
            }
            XCTAssertEqual(resolutions, 320, "Row and column queries must reuse the resolved cell geometry")
        }
    }

    func testEmptyExtentsRemainNull() {
        let noColumns = TableBounds(rowCount: 1, columnCount: 0, bounds: .zero) { _, _ in nil }
        let noRows = TableBounds(rowCount: 0, columnCount: 1, bounds: .zero) { _, _ in nil }
        XCTAssertTrue(noColumns.bounds(forRow: 0).isNull)
        XCTAssertTrue(noRows.bounds(forColumn: 0).isNull)
    }

    func testSharedBoundsMatchLegacyDecorationPixelsWithCustomStylesAndRTL() throws {
        let selectors: [TableBorderSelector] = [.allBorders, .insideBorders, .horizontalBorders, .outsideBorders]
        let strokes = [StrokeStyle(lineWidth: 1), StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [4, 2], dashPhase: 1)]
        let background = TableBackgroundStyle { row, column in
            LinearGradient(
                colors: [Color.blue.opacity(row == 0 ? 0.8 : 0.3), Color.orange.opacity(column == 0 ? 0.8 : 0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for selector in selectors {
                for stroke in strokes {
                    let border = TableBorderStyle(selector, color: .purple.opacity(0.55), strokeStyle: stroke)
                    let actual = try render(DecorationFixture(legacy: false)
                        .markdownTableBackgroundStyle(background)
                        .markdownTableBorderStyle(border)
                        .environment(\.layoutDirection, direction))
                    let expected = try render(DecorationFixture(legacy: true)
                        .markdownTableBackgroundStyle(background)
                        .markdownTableBorderStyle(border)
                        .environment(\.layoutDirection, direction))
                    XCTAssertEqual(actual.width, expected.width)
                    XCTAssertEqual(actual.height, expected.height)
                    let actualData = try pixels(actual)
                    let expectedData = try pixels(expected)
                    XCTAssertTrue(actualData.contains { $0 != 0 }, "The comparison must render visible decoration, not two transparent images")
                    XCTAssertEqual(actualData, expectedData)
                }
            }
        }
    }

    private func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view.padding(4).fixedSize().environment(\.colorScheme, .light))
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func pixels(_ image: CGImage) throws -> Data {
        // Compare visible pixels, excluding ImageRenderer's backing-buffer padding.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}

private struct DecorationFixture: View {
    let legacy: Bool

    var body: some View {
        if legacy {
            cells
                .backgroundPreferenceValue(LegacyCellPreference.self) { anchors in
                    GeometryReader { proxy in
                        TableBackgroundView(tableBounds: resolved(anchors, proxy))
                    }
                }
                .overlayPreferenceValue(LegacyCellPreference.self) { anchors in
                    GeometryReader { proxy in
                        TableBorderView(tableBounds: resolved(anchors, proxy))
                    }
                }
        } else {
            cells.tableDecoration(rowCount: 3, columnCount: 2, background: TableBackgroundView.init, overlay: TableBorderView.init)
        }
    }

    private var cells: some View {
        Grid(horizontalSpacing: 2.5, verticalSpacing: 2.5) {
            ForEach(0 ..< 3, id: \.self) { row in
                GridRow {
                    ForEach(0 ..< 2, id: \.self) { column in
                        Color.clear
                            .frame(width: column == 0 ? 55 : 95, height: CGFloat(25 + row * 10))
                            .tableCellBounds(forRow: row, column: column)
                            .anchorPreference(key: LegacyCellPreference.self, value: .bounds) { anchor in
                                [row * 2 + column: anchor]
                            }
                    }
                }
            }
        }
        .padding(2.5)
    }

    private func resolved(_ anchors: [Int: Anchor<CGRect>], _ proxy: GeometryProxy) -> TableBounds {
        TableBounds(rowCount: 3, columnCount: 2, bounds: proxy.frame(in: .local)) { row, column in
            anchors[row * 2 + column].map { proxy[$0] }
        }
    }
}

private struct LegacyCellPreference: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
#endif
