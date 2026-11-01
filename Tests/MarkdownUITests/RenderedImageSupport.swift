import CoreGraphics
import SwiftUI
import XCTest

/// Renders SwiftUI views to bitmaps so tests can assert on size and pixels on every platform.
@MainActor enum RenderedImage {
    struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        static let clear = Pixel(red: 0, green: 0, blue: 0, alpha: 0)
        static let pureRed = Pixel(red: 255, green: 0, blue: 0, alpha: 255)
        static let pureGreen = Pixel(red: 0, green: 255, blue: 0, alpha: 255)
        static let pureBlue = Pixel(red: 0, green: 0, blue: 255, alpha: 255)
    }

    /// Renders a view at scale 1 using the given proposed size (`nil` lets the view pick its ideal size).
    static func render(
        _ view: some View, width: CGFloat? = nil, height: CGFloat? = nil
    ) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 1
        renderer.proposedSize = .init(width: width, height: height)
        return try XCTUnwrap(renderer.cgImage)
    }

    static func size(of image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }

    /// The RGBA bytes of an image, top row first.
    static func bytes(of image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    /// The pixel at a point measured from the top-left corner of the image.
    static func pixel(in image: CGImage, x: Int, y: Int) throws -> Pixel {
        let bytes = try self.bytes(of: image)
        let offset = (y * image.width + x) * 4
        return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
    }

    /// The pixels of one column, top to bottom.
    static func column(_ x: Int, in image: CGImage) throws -> [Pixel] {
        let bytes = try self.bytes(of: image)
        return (0 ..< image.height).map { y in
            let offset = (y * image.width + x) * 4
            return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
    }

    /// Whether two views render to identical bitmaps.
    static func rendersIdentically(
        _ lhs: some View, _ rhs: some View, width: CGFloat? = nil
    ) throws -> Bool {
        let left = try render(lhs, width: width)
        let right = try render(rhs, width: width)
        guard self.size(of: left) == self.size(of: right) else {
            return false
        }
        return try self.bytes(of: left) == self.bytes(of: right)
    }
}

extension Color {
    /// Fully saturated colors that survive rendering unchanged, unlike the adaptive system colors.
    static let pureRed = Color(red: 1, green: 0, blue: 0)
    static let pureGreen = Color(red: 0, green: 1, blue: 0)
    static let pureBlue = Color(red: 0, green: 0, blue: 1)
}

extension RenderedImage {
    /// Whether a view renders without any content.
    static func rendersNothing(_ view: some View) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            return true
        }
        return image.width == 0 || image.height == 0
    }
}
