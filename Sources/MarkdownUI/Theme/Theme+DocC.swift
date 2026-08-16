import SwiftUI

public extension Theme {
    /// A theme that mimics the DocC style.
    ///
    /// Style | Preview
    /// --- | ---
    /// Inline text | ![](DocCInlines)
    /// Headings | ![](DocCHeading)
    /// Blockquote | ![](DocCBlockquote)
    /// Code block | ![](DocCCodeBlock)
    /// Image | ![](DocCImage)
    /// Task list | Not applicable
    /// Bulleted list | ![](DocCNestedBulletedList)
    /// Numbered list | ![](DocCNumberedList)
    /// Table | ![](DocCTable)
    static let docC = Theme()
        .text {
            ForegroundColor(.text)
        }
        .link {
            ForegroundColor(.link)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.8), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(2))
                }
        }
        .heading2 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.0625))
                .markdownMargin(top: .em(1.6), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.88235))
                }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.07143))
                .markdownMargin(top: .em(1.6), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.64706))
                }
        }
        .heading4 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.083335))
                .markdownMargin(top: .em(1.6), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.41176))
                }
        }
        .heading5 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.09091))
                .markdownMargin(top: .em(1.6), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.29412))
                }
        }
        .heading6 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.235295))
                .markdownMargin(top: .em(1.6), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.235295))
                .markdownMargin(top: .em(0.8), bottom: .zero)
        }
        .blockquote { configuration in
            configuration.label
                .relativePadding(length: .rem(0.94118))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        RoundedRectangle.container
                            .fill(Color.asideNoteBackground)
                        RoundedRectangle.container
                            .strokeBorder(Color.asideNoteBorder)
                    }
                }
                .markdownMargin(top: .em(1.6), bottom: .zero)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.333335))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.rem(0.88235))
                    }
                    .padding(.vertical, 8)
                    .padding(.leading, 14)
            }
            .background(Color.codeBackground)
            .clipShape(.container)
            .markdownMargin(top: .em(0.8), bottom: .zero)
        }
        .image { configuration in
            configuration.label
                .frame(maxWidth: .infinity)
                .markdownMargin(top: .em(1.6), bottom: .em(1.6))
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.8))
        }
        .taskListMarker { _ in
            // DocC renders task lists as bullet lists
            ListBullet.disc
                .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(.horizontalBorders, color: .grid))
                .markdownMargin(top: .em(1.6), bottom: .zero)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.235295))
                .relativePadding(length: .rem(0.58824))
        }
        .thematicBreak {
            Divider()
                .overlay(Color.grid)
                .markdownMargin(top: .em(2.35), bottom: .em(2.35))
        }
}

private extension Shape where Self == RoundedRectangle {
    static var container: Self {
        .init(cornerRadius: 15, style: .continuous)
    }
}

private extension Color {
    static let text = Color(
        light: Color(rgba: 0x1D1D_1FFF), dark: Color(rgba: 0xF5F5_F7FF)
    )
    static let secondaryLabel = Color(
        light: Color(rgba: 0x6E6E_73FF), dark: Color(rgba: 0x8686_8BFF)
    )
    static let link = Color(
        light: Color(rgba: 0x0066_CCFF), dark: Color(rgba: 0x2997_FFFF)
    )
    static let asideNoteBackground = Color(
        light: Color(rgba: 0xF5F5_F7FF), dark: Color(rgba: 0x3232_32FF)
    )
    static let asideNoteBorder = Color(
        light: Color(rgba: 0x6969_69FF), dark: Color(rgba: 0x9A9A_9EFF)
    )
    static let codeBackground = Color(
        light: Color(rgba: 0xF5F5_F7FF), dark: Color(rgba: 0x3333_36FF)
    )
    static let grid = Color(
        light: Color(rgba: 0xD2D2_D7FF), dark: Color(rgba: 0x4242_45FF)
    )
}
