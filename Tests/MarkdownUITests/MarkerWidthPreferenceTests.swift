@testable import MarkdownUI
import SwiftUI
import XCTest

final class MarkerWidthPreferenceTests: XCTestCase {
    func testMaximumWidthCanShrinkOrDisappearOnNextPreferencePass() {
        var width = MarkerWidthPreference.defaultValue
        for next: CGFloat? in [12, nil, 48, 24] {
            MarkerWidthPreference.reduce(value: &width) { next }
        }
        XCTAssertEqual(width, 48)
        width = MarkerWidthPreference.defaultValue
        for next: CGFloat? in [12, 18, nil] {
            MarkerWidthPreference.reduce(value: &width) { next }
        }
        XCTAssertEqual(width, 18)
        width = MarkerWidthPreference.defaultValue
        MarkerWidthPreference.reduce(value: &width) { nil }
        XCTAssertNil(width)
    }
}
