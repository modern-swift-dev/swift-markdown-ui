#if os(macOS)
    import AppKit
    @testable import MarkdownUI
    import SwiftUI
    import XCTest

    @MainActor final class LazyTableRenderingTests: XCTestCase {
        func testExplicitWidthsLimitInitialCreationInOneLargeTable() async throws {
            let counter = TableCellCounter()
            let model = TableContentModel(rowCount: 1000)
            let hostingView = NSHostingView(rootView: scrollingTable(model, counter: counter)
                .markdownTableColumnWidths([110, 140]))
            let window = host(hostingView)
            defer { window.contentView = nil }
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertGreaterThan(counter.cells.count, 0)
            XCTAssertLessThan(counter.cells.count, 200, "Fixed-width tables must not build all 2,000 offscreen cells")

            counter.cells.removeAll()
            model.content = TableContentModel.content(rowCount: 3, prefix: "Updated")
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(counter.cells.filter { $0.contains("Updated") }.count, 6)
            let expectedModel = TableContentModel(rowCount: 3)
            expectedModel.content = TableContentModel.content(rowCount: 3, prefix: "Updated")
            let expectedHost = NSHostingView(rootView: scrollingTable(expectedModel, counter: TableCellCounter())
                .markdownTableColumnWidths([110, 140]))
            let expectedWindow = host(expectedHost)
            defer { expectedWindow.contentView = nil }
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(
                try pixels(capture(hostingView)), try pixels(capture(expectedHost)),
                "After shrinking and replacing content, the mounted table must match a fresh table without stale rows"
            )
        }

        func testMissingMismatchedAndInvalidWidthsPreserveEagerTables() async throws {
            let model = TableContentModel(rowCount: 100)
            let widthCases: [[CGFloat]?] = [nil, [100], [100, 0], [100, .infinity], [100, .nan]]
            for widths in widthCases {
                let counter = TableCellCounter()
                let view = scrollingTable(model, counter: counter)
                let hostingView = NSHostingView(rootView: Group {
                    if let widths {
                        view.markdownTableColumnWidths(widths)
                    } else {
                        view
                    }
                })
                let window = host(hostingView)
                defer { window.contentView = nil }
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(counter.cells.count, 200, "Absent or unusable widths must preserve intrinsic eager layout")
            }
        }

        func testColumnWidthsAndRenderingModeInsideTableThemeEnableLazyRows() async throws {
            let model = TableContentModel(rowCount: 1000)
            let counter = TableCellCounter()
            let hostingView = NSHostingView(rootView: scrollingTable(model, counter: counter, mode: .eager)
                .markdownBlockStyle(\.table) { configuration in
                    configuration.label
                        .markdownTableColumnWidths([110, 140])
                        .markdownBlockRenderingMode(.lazyContainers)
                })
            let window = host(hostingView)
            defer { window.contentView = nil }
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertGreaterThan(counter.cells.count, 0)
            XCTAssertLessThan(counter.cells.count, 200)
        }

        func testFractionalDashedAndCustomStrokesPreserveEagerLayout() async throws {
            let model = TableContentModel(rowCount: 100)
            let strokes = [
                StrokeStyle(lineWidth: 2.5),
                StrokeStyle(lineWidth: 1, dash: [4, 2]),
                StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            ]
            for stroke in strokes {
                let counter = TableCellCounter()
                let hostingView = NSHostingView(rootView: scrollingTable(model, counter: counter)
                    .markdownTableColumnWidths([110, 140])
                    .markdownTableBorderStyle(.init(color: .blue, strokeStyle: stroke)))
                let window = host(hostingView)
                defer { window.contentView = nil }
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(counter.cells.count, 200, "Unsupported strokes must use the eager table's original geometry")
            }
        }

        func testScrollingIntoLargeTablePreservesVisibleRendering() async throws {
            let model = TableContentModel(rowCount: 1000)
            let lazyCounter = TableCellCounter()
            let lazyHost = NSHostingView(rootView: scrollingTable(model, counter: lazyCounter)
                .markdownTableColumnWidths([110, 140]))
            let eagerCounter = TableCellCounter()
            let eagerHost = NSHostingView(rootView: scrollingTable(model, counter: eagerCounter, mode: .eager)
                .markdownTableColumnWidths([110, 140]))
            let lazyWindow = host(lazyHost)
            let eagerWindow = host(eagerHost)
            defer {
                lazyWindow.contentView = nil
                eagerWindow.contentView = nil
            }
            try await Task.sleep(for: .milliseconds(60))
            lazyCounter.cells.removeAll()
            for hosted in [lazyHost as NSView, eagerHost as NSView] {
                let scroll = try XCTUnwrap(findScrollView(in: hosted))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 16000))
                scroll.reflectScrolledClipView(scroll.contentView)
                hosted.layoutSubtreeIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(lazyCounter.cells.contains { cell in
                let row = cell.split(separator: " ").last?.split(separator: ",").first
                return row.flatMap { Int($0) }.map { $0 > 100 } ?? false
            }, "Scrolling must instantiate rows well beyond the initial viewport")
            XCTAssertLessThan(lazyCounter.cells.count, 200)
            let sharedCell = try XCTUnwrap(lazyCounter.positions.keys.sorted().first { label in
                guard let lazyY = lazyCounter.positions[label], let eagerY = eagerCounter.positions[label] else {
                    return false
                }
                return lazyY >= 0 && lazyY < 150 && eagerY >= 0 && eagerY < 150
            })
            let correction = try XCTUnwrap(lazyCounter.positions[sharedCell]) - XCTUnwrap(eagerCounter.positions[sharedCell])
            XCTAssertLessThanOrEqual(abs(correction), 1, "Fixed-height rows should differ only by lazy scroll rounding")
            // Lazy stacks estimate and snap offscreen positions. Align a measured
            // visible cell before comparing pixels, rather than comparing estimates.
            let lazyScroll = try XCTUnwrap(findScrollView(in: lazyHost))
            lazyScroll.contentView.scroll(to: NSPoint(x: 0, y: lazyScroll.contentView.bounds.minY + correction))
            lazyScroll.reflectScrolledClipView(lazyScroll.contentView)
            lazyHost.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(
                try pixels(capture(lazyHost)), try pixels(capture(eagerHost)),
                "Visible row backgrounds and continuous borders must match when the first row is offscreen"
            )
        }

        func testCustomSelectorInsideThemePreservesEagerFallback() async throws {
            let model = TableContentModel(rowCount: 100)
            let counter = TableCellCounter()
            let selector = TableBorderSelector { bounds, _ in [bounds.bounds] }
            let hostingView = NSHostingView(rootView: scrollingTable(model, counter: counter)
                .markdownTableColumnWidths([110, 140])
                .markdownBlockStyle(\.table) { configuration in
                    configuration.label.markdownTableBorderStyle(.init(selector, color: .blue))
                })
            let window = host(hostingView)
            defer { window.contentView = nil }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(counter.cells.count, 200)
        }

        func testSupportedLazyBordersAndCustomStrokeFallbackMatchEagerPixels() async throws {
            let selectors: [TableBorderSelector] = [
                .outsideBorders, .insideBorders, .insideHorizontalBorders,
                .insideVerticalBorders, .horizontalBorders, .allBorders
            ]
            let strokes = [
                StrokeStyle(lineWidth: 1),
                StrokeStyle(lineWidth: 2),
                StrokeStyle(lineWidth: 3),
                StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [4, 2], dashPhase: 1)
            ]
            for (selectorIndex, selector) in selectors.enumerated() {
                for (strokeIndex, stroke) in strokes.enumerated() {
                    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                        let border = TableBorderStyle(selector, color: .purple.opacity(0.55), strokeStyle: stroke)
                        let eager = try await renderSettled(pixelFixture(mode: .eager)
                            .markdownTableBorderStyle(border).environment(\.layoutDirection, direction))
                        let lazy = try await renderSettled(pixelFixture(mode: .lazyContainers)
                            .markdownTableBorderStyle(border).environment(\.layoutDirection, direction))
                        XCTAssertEqual(lazy.width, eager.width)
                        XCTAssertEqual(lazy.height, eager.height)
                        let eagerPixels = try pixels(eager)
                        let lazyPixels = try pixels(lazy)
                        XCTAssertTrue(lazyPixels.contains { $0 != 0 })
                        XCTAssertEqual(lazyPixels, eagerPixels, "Selector \(selectorIndex), stroke \(strokeIndex), direction \(direction)")
                    }
                }
            }
        }

        func testMatchingWidthsAreHonoredInEagerAndTopLevelLazyModes() throws {
            for mode in [MarkdownBlockRenderingMode.eager, .lazy] {
                let image = try render(pixelFixture(mode: mode))
                // Two explicit cell widths, three one-point borders, and render's padding.
                XCTAssertEqual(image.width, Int((55 + 95 + 3 + 8) * 2))
            }
        }

        private func pixelFixture(mode: MarkdownBlockRenderingMode) -> some View {
            let background = TableBackgroundStyle { row, column in
                LinearGradient(
                    colors: [.blue.opacity(row == 0 ? 0.8 : 0.3), .orange.opacity(column == 0 ? 0.8 : 0.2)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            return MarkdownView(TableContentModel.content(rowCount: 3))
                .markdownBlockRenderingMode(mode)
                .markdownTableColumnWidths([55, 95])
                .markdownTableBackgroundStyle(background)
                .markdownBlockStyle(\.table) { configuration in configuration.label }
                .markdownBlockStyle(\.tableCell) { configuration in
                    Color.clear.frame(height: CGFloat(25 + configuration.row * 10))
                }
        }

        private func scrollingTable(
            _ model: TableContentModel, counter: TableCellCounter,
            mode: MarkdownBlockRenderingMode = .lazyContainers
        ) -> some View {
            TableScrollFixture(model: model, counter: counter)
                .markdownBlockRenderingMode(mode)
                .markdownTableBackgroundStyle(.alternatingRows(Color.blue.opacity(0.2), Color.orange.opacity(0.2)))
                .frame(width: 300, height: 200)
        }

        private func host(_ view: NSView) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            return window
        }

        private func findScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                return scroll
            }
            for child in view.subviews {
                if let scroll = findScrollView(in: child) {
                    return scroll
                }
            }
            return nil
        }

        private func renderSettled(_ view: some View) async throws -> CGImage {
            let hostingView = NSHostingView(rootView: view.padding(4).fixedSize().environment(\.colorScheme, .light))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = hostingView
            defer { window.contentView = nil }
            // Lazy stacks refine estimated row heights after their first layout.
            // All three rows fit in this viewport; compare their settled rendering.
            for _ in 0 ..< 10 {
                hostingView.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            hostingView.frame.size = hostingView.fittingSize
            hostingView.layoutSubtreeIfNeeded()
            return try capture(hostingView)
        }

        private func capture(_ view: NSView) throws -> CGImage {
            let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: representation)
            return try XCTUnwrap(representation.cgImage)
        }

        private func render(_ view: some View) throws -> CGImage {
            let renderer = ImageRenderer(content: view.padding(4).fixedSize().environment(\.colorScheme, .light))
            renderer.scale = 2
            return try XCTUnwrap(renderer.cgImage)
        }

        private func pixels(_ image: CGImage) throws -> Data {
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

    @MainActor private final class TableContentModel: ObservableObject {
        @Published var content: MarkdownContent

        init(rowCount: Int) {
            self.content = Self.content(rowCount: rowCount)
        }

        static func content(rowCount: Int, prefix: String = "Cell") -> MarkdownContent {
            MarkdownContent(block: .table(columnAlignments: [.left, .right], rows: (0 ..< rowCount).map { row in
                .init(cells: (0 ..< 2).map { .init(content: [.text("\(prefix) \(row),\($0)")]) })
            }))
        }
    }

    @MainActor private final class TableCellCounter {
        var cells: Set<String> = []
        var positions: [String: CGFloat] = [:]

        func record(_ content: String) -> EmptyView {
            self.cells.insert(content)
            return EmptyView()
        }
    }

    private struct TableScrollFixture: View {
        @ObservedObject var model: TableContentModel
        let counter: TableCellCounter

        var body: some View {
            ScrollView {
                MarkdownView(self.model.content)
                    .markdownBlockStyle(\.tableCell) { configuration in
                        let label = configuration.content.renderPlainText()
                        self.counter.record(label)
                        configuration.label.frame(height: 40)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: TableCellPositionPreference.self,
                                        value: [label: proxy.frame(in: .named(TableScrollCoordinateSpace.viewport)).minY]
                                    )
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: TableScrollCoordinateSpace.viewport)
            .onPreferenceChange(TableCellPositionPreference.self) { self.counter.positions = $0 }
        }
    }

    private enum TableScrollCoordinateSpace: Hashable {
        case viewport
    }

    private struct TableCellPositionPreference: PreferenceKey {
        static let defaultValue: [String: CGFloat] = [:]

        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue()) { $1 }
        }
    }
#endif
