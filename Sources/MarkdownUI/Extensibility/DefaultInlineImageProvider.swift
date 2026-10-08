import Foundation
import ImageIO
import SwiftUI

/// The default inline image provider, which loads and caches images from the network.
public struct DefaultInlineImageProvider: InlineImageProvider {
    /// Controls the decoded image size.
    public enum Resolution: Hashable, Sendable {
        /// Decodes every pixel of the source image.
        case original
        /// Limits the longest decoded dimension in pixels. This also changes intrinsic image size.
        case maximumPixelDimension(Int)
        /// Limits the longest decoded dimension in pixels while keeping the intrinsic image size
        /// of the original resolution, so larger images render with fewer pixels per point.
        case downsampled(maximumPixelDimension: Int)

        func validate() {
            switch self {
                case .original:
                    break
                case let .maximumPixelDimension(dimension),
                     let .downsampled(dimension):
                    precondition(dimension > 0, "The maximum pixel dimension must be positive.")
            }
        }
    }

    let resolution: Resolution

    /// Creates a provider.
    ///
    /// By default, images decode with at most 2048 pixels along their longest side and keep their
    /// original intrinsic size. Pass `.original` to decode every pixel.
    public init(resolution: Resolution = .downsampled(maximumPixelDimension: 2048)) {
        resolution.validate()
        self.resolution = resolution
    }

    public func image(with url: URL, label: String) async throws -> Image {
        let decoded = try await InlineImageLoader.shared.image(for: .init(
            url: url.absoluteURL, resolution: resolution
        ))
        try Task.checkCancellation()
        // Labels belong to occurrences, not cached backing images.
        return Image(decoded.image, scale: decoded.scale, label: Text(label))
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
