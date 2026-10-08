#if os(macOS)
    import AppKit
    @testable import MarkdownUI
    import SwiftUI
    import XCTest

    @MainActor final class NumberedMarkerUpdateTests: XCTestCase {
        func testLiveListChangesMeasureTheSameMarkerWidthAsFreshContent() async throws {
            let recorder = MarkerRecorder()
            let host = NSHostingView(rootView: list(numbered(start: 1, count: 1), fontSize: 16, recorder: recorder))
            let window = makeWindow(host)
            defer { window.contentView = nil }
            try await settle(host)
            XCTAssertGreaterThan(try XCTUnwrap(recorder.width), 0)

            for (start, count, fontSize): (Int, Int, CGFloat) in [
                (1000, 1, 16), (99, 1, 16), (99, 2, 16), (1, 1, 32), (1, 1, 12)
            ] {
                let markdown = numbered(start: start, count: count)
                host.rootView = list(markdown, fontSize: fontSize, recorder: recorder)
                try await settle(host)
                let freshWidth = try await measure(markdown, fontSize: fontSize)
                XCTAssertEqual(
                    try XCTUnwrap(recorder.width), freshWidth, accuracy: 0.5,
                    "start=\(start), count=\(count), fontSize=\(fontSize)"
                )
            }
        }

        func testNestedListMarkersDoNotWidenEnclosingListMarkers() async throws {
            let flatWidth = try await measure("1. Outer", fontSize: 16)
            let wideWidth = try await measure("1000. Outer", fontSize: 16)
            XCTAssertGreaterThan(wideWidth, flatWidth + 0.5, "The fixture needs a visibly wider nested marker")

            for markdown in [
                "1. Outer\n\n   1000. Inner",
                "1. Outer\n\n   - Bullet\n\n     1000. Inner",
                "1. Outer\n\n   > 1000. Quoted"
            ] {
                let nestedWidth = try await measure(markdown, fontSize: 16)
                XCTAssertEqual(nestedWidth, flatWidth, accuracy: 0.5, markdown)
            }
        }

        func testMarkerWidthsDoNotEscapeMarkdownView() async throws {
            let recorder = MarkerRecorder()
            let host = NSHostingView(
                rootView: MarkdownView("1. Outer\n\n   1000. Inner")
                    .onMarkerWidthChange { recorder.width = $0 }
                    .frame(width: 400, alignment: .leading)
            )
            let window = makeWindow(host)
            defer { window.contentView = nil }
            try await settle(host)
            XCTAssertNil(recorder.width)
        }

        private func numbered(start: Int, count: Int) -> String {
            (0 ..< count).map { "\(start + $0). Item \($0)" }.joined(separator: "\n")
        }

        /// Hosts the outer list's items directly so the measured marker widths are
        /// observable before the list view scopes them.
        private func list(_ markdown: String, fontSize: CGFloat, recorder: MarkerRecorder) -> some View {
            guard case let .numberedList(_, start, items) = MarkdownContent(markdown).blocks.first else {
                preconditionFailure("Expected a numbered list: \(markdown)")
            }
            return ListItemSequence(
                items: items,
                start: start,
                markerStyle: Theme.basic.numberedListMarker,
                readsMarkerWidth: true
            )
            .markdownTextStyle { FontSize(fontSize) }
            .onMarkerWidthChange { recorder.width = $0 }
            .frame(width: 400, alignment: .leading)
        }

        private func measure(_ markdown: String, fontSize: CGFloat) async throws -> CGFloat {
            let recorder = MarkerRecorder()
            let host = NSHostingView(rootView: list(markdown, fontSize: fontSize, recorder: recorder))
            let window = makeWindow(host)
            defer { window.contentView = nil }
            try await settle(host)
            return try XCTUnwrap(recorder.width)
        }

        private func makeWindow(_ view: NSView) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            return window
        }

        private func settle(_ view: NSView) async throws {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private final class MarkerRecorder {
        var width: CGFloat?
    }
#endif
