import SwiftUI

public extension View {
    /// Sets the image provider for the Markdown images in a view hierarchy.
    /// - Parameter imageProvider: The image provider to set. Use one of the built-in values, like
    ///                            ``ImageProvider/default`` or ``ImageProvider/asset``,
    ///                            or a custom image provider that you define by creating a type that
    ///                            conforms to the ``ImageProvider`` protocol.
    /// - Returns: A view that uses the specified image provider for itself and its child views.
    func markdownImageProvider(_ imageProvider: some ImageProvider) -> some View {
        self.environment(\.imageProvider, .init(imageProvider))
    }
}

extension EnvironmentValues {
    @Entry var imageProvider: AnyImageProvider = .init(.default)
}
