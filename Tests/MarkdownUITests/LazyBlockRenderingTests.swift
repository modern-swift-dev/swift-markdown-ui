#if os(macOS)
import AppKit
@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class LazyBlockRenderingTests: XCTestCase {
    func testLazyModeLimitsInitialBlockCreationAndEagerRemainsDefault() async throws {
        let content = MarkdownContent((0 ..< 1000).map { "Paragraph \($0)" }.joined(separator: "\n\n"))
        let lazy = Counter()
        let lazyHost = NSHostingView(rootView: view(content, counter: lazy).markdownBlockRenderingMode(.lazy))
        let lazyWindow = host(lazyHost)
        defer { lazyWindow.contentView = nil }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertGreaterThan(lazy.count, 0)
        XCTAssertLessThan(lazy.count, 100, "Offscreen paragraphs should not all be created")

        let eager = Counter()
        let eagerHost = NSHostingView(rootView: view(content, counter: eager))
        let eagerWindow = host(eagerHost)
        defer { eagerWindow.contentView = nil }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(eager.count, 1000)
    }

    private func view(_ content: MarkdownContent, counter: Counter) -> some View {
        ScrollView {
            MarkdownView(content)
                .markdownBlockStyle(\.paragraph) { configuration in
                    configuration.label.frame(height: 40).onAppear { counter.count += 1 }
                }
        }
        .frame(width: 300, height: 200)
    }

    private func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }
}

@MainActor private final class Counter {
    var count = 0
}
#endif
