import SwiftUI

struct ResizeToFit<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ResizeToFitLayout { self.content }
    }
}

private struct ResizeToFitLayout: Layout {
    func makeCache(subviews: Subviews) -> CGSize {
        subviews.first?.sizeThatFits(.unspecified) ?? .zero
    }

    func updateCache(_ cache: inout CGSize, subviews: Subviews) {
        cache = self.makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize) -> CGSize {
        var size = cache

        if let width = proposal.width, size.width > width {
            let aspectRatio = size.width / size.height
            size.width = width
            size.height = width / aspectRatio
        }
        return size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize
    ) {
        guard let view = subviews.first else {
            return
        }
        view.place(at: bounds.origin, proposal: .init(bounds.size))
    }
}
