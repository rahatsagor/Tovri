// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tovri",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "Tovri",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Tovri",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit"),
                // scripts/build.sh embeds Sparkle.framework in Tovri.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "TovriTests", dependencies: ["Tovri"]),
    ]
)
