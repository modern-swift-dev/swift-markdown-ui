import Foundation
import ImageIO
import SwiftUI

/// The default inline image provider, which loads images from the network.
public struct DefaultInlineImageProvider: InlineImageProvider {
    public func image(with url: URL, label: String) async throws -> Image {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
              200 ..< 300 ~= statusCode else {
            throw URLError(.badServerResponse)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw URLError(.cannotDecodeContentData)
        }

        return Image(
            image,
            scale: 1,
            label: Text(label)
        )
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
