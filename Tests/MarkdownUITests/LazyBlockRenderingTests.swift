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

        func testLazyContainersLimitsCreationInsideOneLargeBulletedList() async throws {
            try await assertLazyList((0 ..< 1000).map { "- Item \($0)" }.joined(separator: "\n"))
        }

        func testLazyContainersLimitsCreationInsideOneLargeTaskList() async throws {
            try await assertLazyList((0 ..< 1000).map { "- [ ] Task \($0)" }.joined(separator: "\n"))
        }

        func testLazyContainersLimitsCreationInsideOneLargeNumberedList() async throws {
            try await assertLazyList((0 ..< 1000).map { "\($0 + 1). Item \($0)" }.joined(separator: "\n"))
        }

        func testLazyContainersDefersParagraphsWithinOneBlockquote() async throws {
            let content = MarkdownContent((0 ..< 1000).map { "> Paragraph \($0)" }.joined(separator: "\n>\n"))
            let counter = Counter()
            let hosted = NSHostingView(rootView: view(content, counter: counter).markdownBlockRenderingMode(.lazyContainers))
            let window = host(hosted)
            defer { window.contentView = nil }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertGreaterThan(counter.count, 0)
            XCTAssertLessThan(counter.count, 100)
        }

        private func assertLazyList(_ source: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            let content = MarkdownContent(source)
            XCTAssertEqual(content.blocks.count, 1, file: file, line: line)
            for mode in [MarkdownBlockRenderingMode.lazyContainers, .lazy] {
                let counter = ItemCreationCounter()
                let hosted = NSHostingView(rootView: ScrollView {
                    MarkdownView(content)
                        .markdownBlockRenderingMode(mode)
                        .markdownBlockStyle(\.listItem) { configuration in
                            counter.record(configuration.content.renderPlainText())
                            configuration.label
                        }
                        .markdownBlockStyle(\.paragraph) { configuration in
                            configuration.label.frame(height: 40)
                        }
                }.frame(width: 300, height: 200))
                let window = host(hosted)
                defer { window.contentView = nil }
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertGreaterThan(counter.items.count, 0, file: file, line: line)
                switch mode {
                    case .lazyContainers:
                        XCTAssertLessThan(counter.items.count, 100, "Offscreen list item styles should not be evaluated", file: file, line: line)
                    case .lazy,
                         .eager:
                        XCTAssertEqual(counter.items.count, 1000, "Top-level lazy mode preserves eager container rendering", file: file, line: line)
                }
            }
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

    @MainActor private final class ItemCreationCounter {
        var items: Set<String> = []

        func record(_ item: String) -> EmptyView {
            self.items.insert(item)
            return EmptyView()
        }
    }
#endif
