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

    /// Sets a provider with a stable configuration identity.
    ///
    /// Reuse the same ID across parent updates to preserve loaded images. Change the ID whenever
    /// provider configuration changes in a way that can affect its returned images.
    func markdownInlineImageProvider(
        _ inlineImageProvider: any InlineImageProvider, id: some Hashable & Sendable
    ) -> some View {
        self.environment(\.inlineImageProvider, InlineImageProviderContext(provider: inlineImageProvider, id: id))
    }

}

extension EnvironmentValues {
    @Entry var inlineImageProvider = InlineImageProviderContext(provider: .default)
}

struct InlineImageProviderContext: Sendable {
    enum ID: Equatable, Sendable {
        case defaultProvider(DefaultInlineImageProvider.Resolution)
        case reference(ObjectIdentifier)
        case value(UUID)
        case explicit(ObjectIdentifier, ExplicitID)
    }

    /// Keeps the caller's concrete identity type and its equality without unsafe Sendable erasure.
    struct ExplicitID: Equatable, Sendable {
        private let value: any Sendable
        private let equals: @Sendable (any Sendable) -> Bool

        init<Value: Hashable & Sendable>(_ value: Value) {
            self.value = value
            self.equals = { ($0 as? Value) == value }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.equals(rhs.value)
        }
    }

    let id: ID
    let provider: any InlineImageProvider

    init(provider: any InlineImageProvider, id: some Hashable & Sendable) {
        self.provider = provider
        self.id = .explicit(ObjectIdentifier(type(of: provider)), ExplicitID(id))
    }

    init(provider: any InlineImageProvider) {
        self.provider = provider
        if let provider = provider as? DefaultInlineImageProvider {
            self.id = .defaultProvider(provider.resolution)
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
