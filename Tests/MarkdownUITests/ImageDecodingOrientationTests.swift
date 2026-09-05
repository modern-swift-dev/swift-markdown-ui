import Foundation
import ImageIO
@testable import MarkdownUI
import XCTest

final class ImageDecodingOrientationTests: XCTestCase {
    func testOriginalAndDownsampledDecodingNormalizeEveryEXIFOrientation() throws {
        let cases: [(CGImagePropertyOrientation, [Color], Bool)] = [
            (.up, [.red, .green, .blue, .yellow], false),
            (.upMirrored, [.green, .red, .yellow, .blue], false),
            (.down, [.yellow, .blue, .green, .red], false),
            (.downMirrored, [.blue, .yellow, .red, .green], false),
            (.leftMirrored, [.red, .blue, .green, .yellow], true),
            (.right, [.blue, .red, .yellow, .green], true),
            (.rightMirrored, [.yellow, .green, .blue, .red], true),
            (.left, [.green, .yellow, .red, .blue], true)
        ]
        let resolutions: [DefaultInlineImageProvider.Resolution] = [.original, .maximumPixelDimension(40)]
        for (orientation, expectedColors, swapsAxes) in cases {
            let data = try encodedImage(orientation: orientation)
            for resolution in resolutions {
                let image = try InlineImageLoader.decode(data, resolution: resolution)
                let longest = resolution == .original ? 80 : 40
                XCTAssertEqual(image.width, swapsAxes ? longest / 2 : longest, "Orientation \(orientation)")
                XCTAssertEqual(image.height, swapsAxes ? longest : longest / 2, "Orientation \(orientation)")
                XCTAssertEqual(try quadrantColors(image), expectedColors, "Orientation \(orientation), \(resolution)")
            }
        }
    }

    private enum Color: Equatable {
        case red
        case green
        case blue
        case yellow

        var rgba: [UInt8] {
            switch self {
                case .red: [255, 0, 0, 255]
                case .green: [0, 255, 0, 255]
                case .blue: [0, 0, 255, 255]
                case .yellow: [255, 255, 0, 255]
            }
        }
    }

    private func encodedImage(orientation: CGImagePropertyOrientation) throws -> Data {
        let width = 80
        let height = 40
        var pixels: [UInt8] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                let color: Color = y < height / 2
                    ? (x < width / 2 ? .red : .green)
                    : (x < width / 2 ? .blue : .yellow)
                pixels.append(contentsOf: color.rgba)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as Data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value, orientation.rawValue)
        return data as Data
    }

    private func quadrantColors(_ image: CGImage) throws -> [Color] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return try [
            (image.width / 4, image.height / 4), (image.width * 3 / 4, image.height / 4),
            (image.width / 4, image.height * 3 / 4), (image.width * 3 / 4, image.height * 3 / 4)
        ].map { x, y in
            let offset = (y * image.width + x) * 4
            let channels = Array(pixels[offset ..< offset + 4])
            return try XCTUnwrap([Color.red, .green, .blue, .yellow].first { $0.rgba == channels })
        }
    }
}
