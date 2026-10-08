import SwiftUI

public extension View {
    /// Sets the inline image provider for the Markdown inline images in a view hierarchy.
    ///
    /// Markdown views keep loaded images while the provider keeps its identity. Classes and actors are
    /// identified by reference, and value types that conform to `Hashable` by their value. Other value types
    /// get a new identity on each call, so recreating them during a view update reloads their images; use
    /// `markdownInlineImageProvider(_:id:)` to give them a stable identity.
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
        case asset(AssetInlineImageProvider.ID)
        case reference(ObjectIdentifier)
        case hashable(ExplicitID)
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

        /// Compares a `Hashable` provider by value. `AnyHashable` isn't `Sendable`, so the
        /// `Sendable` provider is retained and erased only while comparing.
        init?(hashableProvider provider: any InlineImageProvider) {
            guard provider is any Hashable else {
                return nil
            }
            self.value = provider
            self.equals = { other in
                guard let lhs = provider as? any Hashable, let rhs = other as? any Hashable else {
                    return false
                }
                return AnyHashable(lhs) == AnyHashable(rhs)
            }
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
            self.id = .asset(asset.id)
        } else if let reference = provider as? any InlineImageProvider & AnyObject {
            self.id = .reference(ObjectIdentifier(reference))
        } else if let hashable = ExplicitID(hashableProvider: provider) {
            // Equal values are interchangeable, so a provider rebuilt in `body` keeps its images.
            self.id = .hashable(hashable)
        } else {
            // An arbitrary value provider has no equality requirement; conservatively reload it.
            self.id = .value(UUID())
        }
    }
}
