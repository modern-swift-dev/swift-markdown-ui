import SwiftUI

public extension View {
    /// Sets the inline image provider for the Markdown inline images in a view hierarchy.
    /// - Parameter inlineImageProvider: The inline image provider to set. Use one of the built-in values, like
    ///                                  ``InlineImageProvider/default`` or ``InlineImageProvider/asset``,
    ///                                  or a custom inline image provider that you define by creating a type that
    ///                                  conforms to the ``InlineImageProvider`` protocol.
    /// - Returns: A view that uses the specified inline image provider for itself and its child views.
    func markdownInlineImageProvider(_ inlineImageProvider: InlineImageProvider) -> some View {
        self.environment(\.inlineImageProvider, InlineImageProviderContext(provider: inlineImageProvider))
    }
}

extension EnvironmentValues {
    @Entry var inlineImageProvider = InlineImageProviderContext(provider: .default)
}

struct InlineImageProviderContext: Sendable {
    enum ID: Equatable, Sendable {
        case defaultProvider
        case reference(ObjectIdentifier)
        case value(UUID)
    }

    let id: ID
    let provider: any InlineImageProvider

    init(provider: any InlineImageProvider) {
        self.provider = provider
        if provider is DefaultInlineImageProvider {
            self.id = .defaultProvider
        } else if let asset = provider as? AssetInlineImageProvider {
            self.id = .value(asset.id)
        } else if let reference = provider as? any InlineImageProvider & AnyObject {
            self.id = .reference(ObjectIdentifier(reference))
        } else {
            // An arbitrary value provider has no equality requirement; conservatively reload it.
            self.id = .value(UUID())
        }
    }
}
