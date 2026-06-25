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
    dependencies: [],
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
            ],
            path: "Sources/App",
            resources: [
                .process("Resources"),
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
            path: "Tests/QuestmasterLogicTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
