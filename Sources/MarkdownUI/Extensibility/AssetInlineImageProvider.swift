import SwiftUI

/// An inline image provider that loads images from resources located in an app or a module.
public struct AssetInlineImageProvider: InlineImageProvider {
    /// Closures aren't comparable, so only the default name mapping has a value identity.
    enum ID: Hashable, Sendable {
        case lastPathComponent(Bundle?)
        case instance(UUID)
    }

    static let defaultProvider = AssetInlineImageProvider()
    let id: ID

    private let name: @Sendable (URL) -> String
    private let bundle: Bundle?

    /// Creates an asset inline image provider.
    /// - Parameters:
    ///   - name: A closure that extracts the image resource name from the URL in the Markdown content.
    ///   - bundle: The bundle where the image resources are located. Specify `nil` to search the app’s main bundle.
    public init(
        name: @escaping @Sendable (URL) -> String = \.lastPathComponent,
        bundle: Bundle? = nil
    ) {
        self.name = name
        self.bundle = bundle
        self.id = .instance(UUID())
    }

    /// Creates an asset inline image provider that uses the last path component of each URL as the resource name.
    ///
    /// Providers created with this initializer and the same bundle are interchangeable, so recreating
    /// one during a view update preserves the images that are already loaded.
    /// - Parameter bundle: The bundle where the image resources are located. Specify `nil` to search
    ///                     the app’s main bundle.
    public init(bundle: Bundle? = nil) {
        self.name = \.lastPathComponent
        self.bundle = bundle
        self.id = .lastPathComponent(bundle)
    }

    /// Throws when the bundle has no image with the resource name, so the image's alt text is shown.
    public func image(with url: URL, label: String) async throws -> Image {
        let name = self.name(url)
        guard Self.hasImage(named: name, in: self.bundle) else {
            throw URLError(.fileDoesNotExist)
        }
        return .init(name, bundle: self.bundle, label: Text(label))
    }

    private static func hasImage(named name: String, in bundle: Bundle?) -> Bool {
        #if canImport(UIKit)
            UIImage(named: name, in: bundle, with: nil) != nil
        #elseif canImport(AppKit)
            (bundle ?? .main).image(forResource: name) != nil
        #endif
    }
}

public extension InlineImageProvider where Self == AssetInlineImageProvider {
    /// An inline image provider that loads images from resources located in an app or a module.
    ///
    /// Use the `markdownInlineImageProvider(_:)` modifier to configure this image provider for a view hierarchy.
    static var asset: Self {
        .defaultProvider
    }
}
