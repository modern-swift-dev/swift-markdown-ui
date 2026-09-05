#if os(macOS)
import AppKit
@testable import MarkdownUI
import SwiftUI
import XCTest

@MainActor final class BlockSequenceIdentityTests: XCTestCase {
    func testContentUpdatesDoNotHashOrRecreateChildren() async throws {
        let recorder = Recorder()
        let host = NSHostingView(rootView: sequence(["first", "second"], recorder: recorder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await settle()
        let original = recorder.identities
        XCTAssertEqual(original.count, 2)
        for revision in 0 ..< 10 {
            host.rootView = sequence(["edited \(revision)", "second"], recorder: recorder)
            host.layoutSubtreeIfNeeded()
            try await settle()
        }
        XCTAssertEqual(recorder.identities, original)
        XCTAssertEqual(recorder.hashCount, 0)
        host.rootView = sequence(["remaining"], recorder: recorder)
        host.layoutSubtreeIfNeeded()
        try await settle()
        host.rootView = sequence(["remaining", "new"], recorder: recorder)
        host.layoutSubtreeIfNeeded()
        try await settle()
        XCTAssertEqual(recorder.identities[0], original[0])
        XCTAssertNotEqual(recorder.identities[1], original[1])
        XCTAssertEqual(recorder.hashCount, 0)
    }

    private func sequence(_ values: [String], recorder: Recorder) -> some View {
        BlockSequence(values.map { Value(text: $0, recorder: recorder) }) { index, value in
            StatefulLabel(index: index, text: value.text, recorder: recorder)
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(10))
    }
}

private final class Recorder {
    var identities: [Int: UUID] = [:]
    var hashCount = 0
}

private struct Value: Hashable {
    let text: String
    let recorder: Recorder

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
    }

    func hash(into hasher: inout Hasher) {
        recorder.hashCount += 1
        hasher.combine(text)
    }
}

private struct StatefulLabel: View {
    let index: Int
    let text: String
    let recorder: Recorder
    @State private var identity = UUID()

    var body: some View {
        Text(text)
            .markdownMargin(top: CGFloat(index + 1))
            .onAppear { recorder.identities[index] = identity }
            .onChange(of: text) { recorder.identities[index] = identity }
    }
}
#endif
