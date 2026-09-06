import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if canImport(UIKit) || canImport(AppKit)
    extension NSAttributedString.Key {
        static let markdownEditorStrong = NSAttributedString.Key("MarkdownUIEditor.Strong")
        static let markdownEditorEmphasis = NSAttributedString.Key("MarkdownUIEditor.Emphasis")
        static let markdownEditorStrikethrough = NSAttributedString.Key("MarkdownUIEditor.Strikethrough")
        static let markdownEditorCode = NSAttributedString.Key("MarkdownUIEditor.Code")
        static let markdownEditorInlineHTML = NSAttributedString.Key("MarkdownUIEditor.InlineHTML")
        static let markdownEditorLinkDestination = NSAttributedString.Key("MarkdownUIEditor.LinkDestination")
        static let markdownEditorLinkTitle = NSAttributedString.Key("MarkdownUIEditor.LinkTitle")
        static let markdownEditorHardBreak = NSAttributedString.Key("MarkdownUIEditor.HardBreak")
    }

    /// Converts one rich TextKit leaf back into typed inline nodes.
    ///
    /// TextKit permits style combinations whose overlap cannot be represented exactly
    /// by Markdown. The decoder uses the stable nesting order link, strong,
    /// emphasis, and strikethrough, including around code and inline HTML.
    enum MarkdownAttributedInlineDecoder {
        static func decode(_ attributedString: NSAttributedString) -> [MarkdownInline] {
            guard attributedString.length > 0 else {
                return []
            }

            var result: [MarkdownInline] = []
            attributedString.enumerateAttributes(
                in: NSRange(location: 0, length: attributedString.length),
                options: []
            ) { attributes, range, _ in
                let value = (attributedString.string as NSString).substring(with: range)
                if let attachment = attributes[.attachment] as? MarkdownImageAttachment {
                    let metadata = attachment.metadata
                    append(
                        styledInline(
                            .image(
                                source: metadata.source,
                                title: metadata.title,
                                children: attachment.altContent
                            ),
                            attributes: attributes
                        ),
                        to: &result
                    )
                    return
                }

                var textStart = value.startIndex
                for index in value.indices where value[index] == "\n" {
                    if textStart < index {
                        append(styledText(String(value[textStart ..< index]), attributes: attributes), to: &result)
                    }
                    let hardBreak = (attributes[.markdownEditorHardBreak] as? NSNumber)?.boolValue == true
                    append(hardBreak ? .lineBreak : .softBreak, to: &result)
                    textStart = value.index(after: index)
                }
                if textStart < value.endIndex {
                    append(styledText(String(value[textStart...]), attributes: attributes), to: &result)
                }
            }
            return result
        }

        private static func styledText(
            _ text: String,
            attributes: [NSAttributedString.Key: Any]
        ) -> MarkdownInline {
            if (attributes[.markdownEditorInlineHTML] as? NSNumber)?.boolValue == true {
                return styledInline(.html(text), attributes: attributes)
            }
            if (attributes[.markdownEditorCode] as? NSNumber)?.boolValue == true {
                return styledInline(.code(text), attributes: attributes)
            }

            return styledInline(.text(text), attributes: attributes)
        }

        private static func styledInline(
            _ base: MarkdownInline,
            attributes: [NSAttributedString.Key: Any]
        ) -> MarkdownInline {
            var inline = base
            if (attributes[.markdownEditorStrikethrough] as? NSNumber)?.boolValue == true {
                inline = .strikethrough([inline])
            }
            if (attributes[.markdownEditorEmphasis] as? NSNumber)?.boolValue == true {
                inline = .emphasis([inline])
            }
            if (attributes[.markdownEditorStrong] as? NSNumber)?.boolValue == true {
                inline = .strong([inline])
            }
            if let destination = attributes[.markdownEditorLinkDestination] as? String {
                inline = .link(
                    destination: destination,
                    title: attributes[.markdownEditorLinkTitle] as? String,
                    children: [inline]
                )
            }
            return inline
        }

        private static func append(_ inline: MarkdownInline, to result: inout [MarkdownInline]) {
            guard let previous = result.last, let merged = merge(previous, inline) else {
                result.append(inline)
                return
            }
            result[result.count - 1] = merged
        }

        private static func merge(_ lhs: MarkdownInline, _ rhs: MarkdownInline) -> MarkdownInline? {
            switch (lhs, rhs) {
                case let (.text(first), .text(second)):
                    .text(first + second)
                case let (.code(first), .code(second)):
                    .code(first + second)
                case let (.html(first), .html(second)):
                    .html(first + second)
                case let (.strong(first), .strong(second)):
                    .strong(mergingChildren(first, second))
                case let (.emphasis(first), .emphasis(second)):
                    .emphasis(mergingChildren(first, second))
                case let (.strikethrough(first), .strikethrough(second)):
                    .strikethrough(mergingChildren(first, second))
                case let (
                .link(firstDestination, firstTitle, firstChildren),
                .link(secondDestination, secondTitle, secondChildren)
            )
                where firstDestination == secondDestination && firstTitle == secondTitle:
                    .link(
                        destination: firstDestination,
                        title: firstTitle,
                        children: mergingChildren(firstChildren, secondChildren)
                    )
                default:
                    nil
            }
        }

        private static func mergingChildren(
            _ lhs: [MarkdownInline],
            _ rhs: [MarkdownInline]
        ) -> [MarkdownInline] {
            var result = lhs
            for inline in rhs {
                append(inline, to: &result)
            }
            return result
        }
    }
#endif
