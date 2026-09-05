@testable import MarkdownUI
import SwiftUI
import XCTest

final class FlowLayoutCacheTests: XCTestCase {
    func testSizeAndPlacementShareRowsUntilLayoutInputsChange() {
        var cache = FlowLayout.Cache()
        var measurements = 0
        func compute() -> [FlowLayout.Row] {
            measurements += 1
            return [.init(size: CGSize(width: 100, height: 30), items: [])]
        }
        let key = FlowLayout.Cache.Key(proposal: .init(width: 300, height: nil), horizontalSpacing: 4, verticalSpacing: 4)
        let measured = cache.rows(for: key, compute: compute)
        let placed = cache.rows(for: key, compute: compute)
        XCTAssertEqual(measurements, 1)
        XCTAssertEqual(measured.first?.size, placed.first?.size)
        _ = cache.rows(for: .init(proposal: .init(width: 200, height: nil), horizontalSpacing: 4, verticalSpacing: 4), compute: compute)
        _ = cache.rows(for: .init(proposal: .init(width: 200, height: nil), horizontalSpacing: 8, verticalSpacing: 4), compute: compute)
        XCTAssertEqual(measurements, 3)
        // updateCache discards cached measurements when the subviews change.
        cache = FlowLayout.Cache()
        _ = cache.rows(for: key, compute: compute)
        XCTAssertEqual(measurements, 4)
    }
}
