import SwiftUI

extension View {
    func readMarkerWidth() -> some View {
        self.background(
            GeometryReader { proxy in
                Color.clear.preference(key: MarkerWidthPreference.self, value: proxy.size.width)
            }
        )
    }

    func onMarkerWidthChange(perform action: @escaping (CGFloat?) -> Void) -> some View {
        self.onPreferenceChange(MarkerWidthPreference.self, perform: action)
    }
}

struct MarkerWidthPreference: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        guard let next = nextValue() else {
            return
        }
        value = value.map { max($0, next) } ?? next
    }
}
