// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "swift-markdown-ui",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
        .tvOS(.v17),
        .macCatalyst(.v17),
        .watchOS(.v10),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "MarkdownUI",
            targets: ["MarkdownUI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/modern-swift-dev/swift-snapshot-testing", from: "2.2.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.8.0")
    ],
    targets: [
        .target(
            name: "MarkdownUI",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark")
            ]
        ),
        .testTarget(
            name: "MarkdownUITests",
            dependencies: [
                "MarkdownUI",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            exclude: ["__Snapshots__"]
        )
    ],
    swiftLanguageModes: [.v6]
)
