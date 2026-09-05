import SwiftUI

/// The default image provider, which shares network loads and decoded images with
/// the default inline image provider.
public struct DefaultImageProvider: ImageProvider {
    public typealias Resolution = DefaultInlineImageProvider.Resolution

    private let resolution: Resolution

    /// Creates a provider. Downsampling is opt-in because it changes intrinsic image size.
    public init(resolution: Resolution = .original) {
        if case let .maximumPixelDimension(dimension) = resolution {
            precondition(dimension > 0, "The maximum pixel dimension must be positive.")
        }
        self.resolution = resolution
    }

    public func makeImage(url: URL?) -> some View {
        DefaultImageView(url: url, resolution: self.resolution)
    }
}

struct DefaultImageView: View {
    private enum Phase {
        case loaded(InlineImageLoader.Key, CGImage)
        case failed(InlineImageLoader.Key)
    }

    private let key: InlineImageLoader.Key?
    private let loader: InlineImageLoader
    @State private var phase: Phase?

    init(
        url: URL?,
        resolution: DefaultImageProvider.Resolution = .original,
        loader: InlineImageLoader = .shared
    ) {
        self.key = url.map { .init(url: $0.absoluteURL, resolution: resolution) }
        self.loader = loader
    }

    var body: some View {
        self.content.task(id: self.key) {
            guard !Task.isCancelled else {
                return
            }
            guard let key = self.key else {
                self.phase = nil
                return
            }
            // Release any backing image from the previous resource while loading.
            self.phase = nil
            do {
                let image = try await self.loader.image(for: key)
                try Task.checkCancellation()
                self.phase = .loaded(key, image)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self.phase = .failed(key)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch self.phase {
            case let .loaded(key, image) where key == self.key:
                ResizeToFit {
                    // ImageView supplies the occurrence's accessibility label and link.
                    Image(image, scale: 1, label: Text("")).resizable()
                }
            case let .failed(key) where key == self.key:
                self.failurePlaceholder
            default:
                if self.key == nil {
                    self.failurePlaceholder
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
        }
    }

    private var failurePlaceholder: some View {
        Image(systemName: "exclamationmark.triangle")
            .imageScale(.large)
            .foregroundStyle(.secondary)
            .padding()
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
