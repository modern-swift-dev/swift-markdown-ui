import Foundation
import ImageIO
import SwiftUI

/// The default inline image provider, which loads and caches images from the network.
public struct DefaultInlineImageProvider: InlineImageProvider {
    /// Controls the decoded image size. Original resolution preserves intrinsic image sizing.
    public enum Resolution: Hashable, Sendable {
        case original
        /// Limits the longest decoded dimension in pixels. This also changes intrinsic image size.
        case maximumPixelDimension(Int)
    }

    let resolution: Resolution

    /// Creates a provider. Downsampling is opt-in because it changes intrinsic image size.
    public init(resolution: Resolution = .original) {
        if case let .maximumPixelDimension(dimension) = resolution {
            precondition(dimension > 0, "The maximum pixel dimension must be positive.")
        }
        self.resolution = resolution
    }

    public func image(with url: URL, label: String) async throws -> Image {
        let image = try await InlineImageLoader.shared.image(for: .init(
            url: url.absoluteURL, resolution: resolution
        ))
        try Task.checkCancellation()
        // Labels belong to occurrences, not cached backing images.
        return Image(image, scale: 1, label: Text(label))
    }
}

public extension InlineImageProvider where Self == DefaultInlineImageProvider {
    /// The default inline image provider, which loads images from the network.
    ///
    /// Use the `markdownInlineImageProvider(_:)` modifier to configure
    /// this image provider for a view hierarchy.
    static var `default`: Self {
        .init()
    }
}
