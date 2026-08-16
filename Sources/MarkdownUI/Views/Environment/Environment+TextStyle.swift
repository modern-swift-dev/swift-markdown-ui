import SwiftUI

extension View {
    /// Sets the default text style for the Markdown inlines in a view hierarchy.
    ///
    /// Use this modifier inside a ``BlockStyle`` `body` block to customize
    /// the default text style for the block's Markdown inlines.
    ///
    /// - Parameter textStyle: A text style builder that returns the text style to use.
    public func markdownTextStyle(
        @TextStyleBuilder textStyle: @escaping () -> some TextStyle
    ) -> some View {
        self.transformEnvironment(\.textStyle) {
            $0 = $0.appending(textStyle())
        }
    }

    func textStyleFont() -> some View {
        TextStyleAttributesReader { attributes in
            self.font(attributes.fontProperties.map(Font.withProperties))
        }
    }

    func textStyleForegroundColor() -> some View {
        TextStyleAttributesReader { attributes in
            self.foregroundColor(attributes.foregroundColor)
        }
    }

    func textStyle(_ textStyle: TextStyle) -> some View {
        self.transformEnvironment(\.textStyle) {
            $0 = $0.appending(textStyle)
        }
    }
}

private extension TextStyle {
    @TextStyleBuilder func appending(
        _ textStyle: some TextStyle
    ) -> some TextStyle {
        self
        textStyle
    }
}

extension EnvironmentValues {
    @Entry fileprivate(set) var textStyle: TextStyle = FontProperties()
}
