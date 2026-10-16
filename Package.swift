// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pane",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.6.0"),
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),
        .executableTarget(
            name: "Pane",
            dependencies: [
                "GhosttyKit",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
