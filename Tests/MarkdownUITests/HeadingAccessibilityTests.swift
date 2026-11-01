@testable import MarkdownUI
import SwiftUI
import XCTest

final class HeadingAccessibilityTests: XCTestCase {
    func testHeadingsExposeTheirLevelToAssistiveTechnologies() {
        XCTAssertEqual(
            (1 ... 6).map(AccessibilityHeadingLevel.init(markdownLevel:)),
            [.h1, .h2, .h3, .h4, .h5, .h6]
        )
    }
}
