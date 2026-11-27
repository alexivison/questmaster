// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Questmaster",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Questmaster", targets: ["Questmaster"]),
        .executable(name: "QuestmasterLogicTests", targets: ["QuestmasterLogicTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.4.0"),
    ],
    targets: [
        .binaryTarget(
            name: "CGhosttyKitBinary",
            url: "https://github.com/alexivison/questmaster/releases/download/ghosttykit-0.8.0/GhosttyKit.xcframework.zip",
            checksum: "b76a33a177050513a15009494f13416c4eda493433a15f0666577908991ec81d"
        ),
        .target(
            name: "GhosttyKit",
            dependencies: [
                "CGhosttyKitBinary",
            ],
            path: "Vendor/GhosttyKit-0.8.0/Sources/GhosttyKitExports",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "QuestmasterCore",
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "Questmaster",
            dependencies: [
                "QuestmasterCore",
                "GhosttyKit",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Sources/App",
            resources: [
                .process("Resources/AgentLogos"),
                .process("Resources/Portraits"),
                // A class's sprites keep their folder, so two classes can name a frame the same.
                .copy("Resources/Sprites"),
                // A worker's familiar, one folder per class like the sprites; the shared bubble is read from Sprites/shared.
                .copy("Resources/Familiars"),
                // The line and filled drawings keep their folders (`Icons/line`, `Icons/filled`), as `AppIcon` reads them.
                .copy("Resources/Icons"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(
            name: "QuestmasterLogicTests",
            dependencies: [
                "QuestmasterCore",
            ],
            path: "Tests/QuestmasterLogicTests",
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
