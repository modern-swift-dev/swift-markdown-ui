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

    func testAlternatingProposalsReuseRowsWithinCapacity() {
        var cache = FlowLayout.Cache()
        var measurements = 0
        // A typical pass measures ideal, minimum, and maximum sizes, then places at the final width.
        let proposals: [ProposedViewSize] = [.unspecified, .zero, .infinity, .init(width: 320, height: nil)]
        XCTAssertEqual(proposals.count, FlowLayout.Cache.capacity)
        for _ in 0 ..< 3 {
            for proposal in proposals {
                let rows = cache.rows(for: key(proposal)) {
                    measurements += 1
                    return [.init(size: CGSize(width: proposal.width ?? -1, height: 30), items: [])]
                }
                XCTAssertEqual(rows.first?.size.width, proposal.width ?? -1, "Each proposal must get its own rows")
            }
        }
        XCTAssertEqual(measurements, proposals.count)
    }

    func testFullCacheEvictsTheLeastRecentlyUsedProposal() {
        var cache = FlowLayout.Cache()
        var measured: [CGFloat] = []
        func rows(_ width: CGFloat) {
            _ = cache.rows(for: key(.init(width: width, height: nil))) {
                measured.append(width)
                return []
            }
        }
        for width: CGFloat in [100, 200, 300, 400] {
            rows(width)
        }
        // Using 100 again makes 200 the least recently used entry.
        rows(100)
        rows(500)
        XCTAssertEqual(measured, [100, 200, 300, 400, 500])
        rows(100)
        rows(300)
        rows(400)
        rows(500)
        XCTAssertEqual(measured, [100, 200, 300, 400, 500], "Recently used proposals must stay cached")
        rows(200)
        XCTAssertEqual(measured, [100, 200, 300, 400, 500, 200], "The least recently used proposal must be evicted")
    }

    private func key(_ proposal: ProposedViewSize) -> FlowLayout.Cache.Key {
        .init(proposal: proposal, horizontalSpacing: 4, verticalSpacing: 4)
    }
}
