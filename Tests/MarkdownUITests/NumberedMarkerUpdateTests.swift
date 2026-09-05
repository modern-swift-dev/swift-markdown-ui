#if os(macOS)
import AppKit
@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class NumberedMarkerUpdateTests: XCTestCase {
    func testLiveListChangesMeasureTheSameMarkerWidthAsFreshContent() async throws {
        let recorder = MarkerRecorder()
        let host = NSHostingView(rootView: list(start: 1, count: 1, fontSize: 16, recorder: recorder))
        let window = makeWindow(host)
        defer { window.contentView = nil }
        try await settle(host)
        XCTAssertGreaterThan(try XCTUnwrap(recorder.width), 0)

        for (start, count, fontSize): (Int, Int, CGFloat) in [
            (1000, 1, 16), (99, 1, 16), (99, 2, 16), (1, 1, 32), (1, 1, 12)
        ] {
            host.rootView = list(start: start, count: count, fontSize: fontSize, recorder: recorder)
            try await settle(host)
            let freshRecorder = MarkerRecorder()
            let fresh = NSHostingView(rootView: list(start: start, count: count, fontSize: fontSize, recorder: freshRecorder))
            let freshWindow = makeWindow(fresh)
            defer { freshWindow.contentView = nil }
            try await settle(fresh)
            XCTAssertEqual(
                try XCTUnwrap(recorder.width), try XCTUnwrap(freshRecorder.width), accuracy: 0.5,
                "start=\(start), count=\(count), fontSize=\(fontSize)"
            )
        }
    }

    private func list(start: Int, count: Int, fontSize: CGFloat, recorder: MarkerRecorder) -> some View {
        MarkdownView((0 ..< count).map { "\(start + $0). Item \($0)" }.joined(separator: "\n"))
            .markdownTheme(.basic.text { FontSize(fontSize) })
            .onMarkerWidthChange { recorder.width = $0 }
            .frame(width: 400, alignment: .leading)
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
