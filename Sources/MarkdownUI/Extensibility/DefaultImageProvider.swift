import SwiftUI

/// The default image provider, which loads images from the network.
public struct DefaultImageProvider: ImageProvider {
    public func makeImage(url: URL?) -> some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                ResizeToFit {
                    image.resizable()
                }
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
            }
        }
    }
}

public extension ImageProvider where Self == DefaultImageProvider {
    /// The default image provider, which loads images from the network.
    ///
    /// Use the `markdownImageProvider(_:)` modifier to configure this image provider for a view hierarchy.
    static var `default`: Self {
        .init()
    }
}
