import Foundation
import QuartzCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Draws task markers sized to the theme's body font.
@MainActor final class MarkdownTaskCheckboxLayer: CAShapeLayer {
    private struct ShapeConfiguration: Equatable {
        let size: CGFloat
        let checked: Bool
    }

    private var shapeConfiguration: ShapeConfiguration?

    struct Metrics {
        let boxSize: CGFloat
        var gutterWidth: CGFloat {
            max(44, boxSize + 16)
        }

        var paragraphSpacing: CGFloat {
            boxSize / 4
        }

        @MainActor init(theme: MarkdownEditorTheme) {
            #if canImport(UIKit)
                let font = theme.bodyAttributes[.font] as? UIFont ?? UIFont.preferredFont(forTextStyle: .body)
            #else
                let font = theme.bodyAttributes[.font] as? NSFont ?? NSFont.preferredFont(forTextStyle: .body)
            #endif
            boxSize = font.pointSize * 1.2
        }
    }

    func update(textRect: CGRect, checked: Bool, color: CGColor, theme: MarkdownEditorTheme) {
        if shapeConfiguration == nil {
            actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
            fillColor = nil
            lineCap = .round
            lineJoin = .round
        }
        let metrics = Metrics(theme: theme)
        let size = metrics.boxSize
        frame = CGRect(x: textRect.minX - metrics.gutterWidth + (metrics.gutterWidth - size) / 2, y: textRect.midY - size / 2, width: size, height: size)
        strokeColor = color
        let configuration = ShapeConfiguration(size: size, checked: checked)
        guard shapeConfiguration != configuration else {
            return
        }
        shapeConfiguration = configuration
        let scale = size / 24
        let shape = CGMutablePath()
        shape.addRoundedRect(in: CGRect(x: scale, y: scale, width: size - 2 * scale, height: size - 2 * scale), cornerWidth: 4 * scale, cornerHeight: 4 * scale)
        if checked {
            shape.move(to: CGPoint(x: 6 * scale, y: 12 * scale))
            shape.addLine(to: CGPoint(x: 10 * scale, y: 16 * scale))
            shape.addLine(to: CGPoint(x: 18 * scale, y: 8 * scale))
        }
        path = shape
        lineWidth = 2 * scale
    }

    static func hitBounds(textRect: CGRect, theme: MarkdownEditorTheme) -> CGRect {
        let size = Metrics(theme: theme).gutterWidth
        return CGRect(x: textRect.minX - size, y: textRect.midY - size / 2, width: size, height: size)
    }
}
