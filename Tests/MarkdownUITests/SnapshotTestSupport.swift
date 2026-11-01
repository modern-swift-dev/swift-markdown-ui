import Foundation
import SnapshotTesting
import Testing
#if os(macOS)
    import AppKit
    import SwiftUI
#endif

@Suite(.serialized, .snapshots(SnapshotTestSupport.configuration)) struct SnapshotTests {}

enum SnapshotTestSupport {
    #if os(iOS)
        static var supportsPhoneSnapshots: Bool {
            // Mac Catalyst uses the iPad idiom and has no host app to render phone snapshots in.
            !ProcessInfo.processInfo.isMacCatalystApp
                && ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") != true
        }

        /// iOS references keep the bare test name.
        static let referenceName: String? = nil
    #elseif os(macOS)
        /// macOS renders phone snapshots in a window the size of the iOS device.
        static let supportsPhoneSnapshots = true

        /// Keeps macOS references apart from the iOS references recorded for the same test.
        static let referenceName: String? = "macOS"

        /// The point size of the iPhone 8 device that the iOS snapshots use.
        static let phoneSize = CGSize(width: 375, height: 667)
    #endif

    static var configuration: SnapshotTestingConfiguration {
        SnapshotTestingConfiguration(
            record: ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" ? .all : .missing,
            snapshotNaming: .testName,
            referenceStorage: .directory("__Snapshots__", relativeTo: .testTarget)
        )
    }
}

#if os(macOS)
    extension Snapshotting where Value: SwiftUI.View, Format == NSImage {
        /// Hosts the view in a window at a fixed size, lets it settle for 0.2 seconds, and draws the hosting view at 2x.
        ///
        /// The library's macOS SwiftUI strategy renders with `ImageRenderer`, which leaves out the content of
        /// scroll views, including the horizontal scroll views that hold code blocks.
        ///
        /// Images must match exactly. On macOS the library's perceptual comparison raises an Objective-C
        /// exception (`-[NSConcreteValue CGRectValue]`) instead of reporting a mismatch.
        @MainActor static func windowImage(
            width: CGFloat,
            height: CGFloat
        ) -> Snapshotting {
            Snapshotting<NSImage, NSImage>.image(isOpaque: true).asyncPullback { view in
                let size = CGSize(width: width, height: height)
                let hostingView = NSHostingView(rootView: view.frame(width: width, height: height))
                let window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.contentView = hostingView
                hostingView.layoutSubtreeIfNeeded()
                return Async { callback in
                    // A run loop timer, unlike the main queue, fires while a Swift Testing test on the main
                    // actor waits for the snapshot.
                    let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            hostingView.layoutSubtreeIfNeeded()
                            let scale = 2
                            guard let bitmap = NSBitmapImageRep(
                                bitmapDataPlanes: nil,
                                pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                            ) else {
                                preconditionFailure("Could not create a bitmap for the snapshot")
                            }
                            bitmap.size = size
                            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
                            window.contentView = nil
                            let image = NSImage(size: size)
                            image.addRepresentation(bitmap)
                            callback(image)
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                }
            }
        }
    }
#endif
