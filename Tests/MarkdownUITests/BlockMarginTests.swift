@testable import MarkdownUI
import SwiftUI
import XCTest

final class BlockMarginTests: XCTestCase {
    func testCollapsedMarginsPreserveUnspecifiedAndNegativeSpacing() {
        let values: [CGFloat?] = [nil, -20, -1, 0, 12, 48]
        for lhs in values {
            for rhs in values {
                XCTAssertEqual(BlockMargin.maximum(lhs, rhs), [lhs, rhs].compactMap(\.self).max())
            }
        }
    }

    func testPreferenceReductionKeepsTopAndBottomIndependentAndCanShrink() {
        var margin = BlockMarginsPreference.defaultValue
        for next in [BlockMargin(top: 12), BlockMargin(bottom: -4), BlockMargin(top: 6, bottom: -2)] {
            BlockMarginsPreference.reduce(value: &margin) { next }
        }
        XCTAssertEqual(margin, BlockMargin(top: 12, bottom: -2))
        margin = BlockMarginsPreference.defaultValue
        BlockMarginsPreference.reduce(value: &margin) { BlockMargin(top: 3) }
        XCTAssertEqual(margin, BlockMargin(top: 3))
        margin = BlockMarginsPreference.defaultValue
        BlockMarginsPreference.reduce(value: &margin) { .unspecified }
        XCTAssertEqual(margin, .unspecified)
    }
}
