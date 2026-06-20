// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Questmaster",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "Questmaster", targets: ["Questmaster"]),
        .executable(name: "QuestmasterLogicTests", targets: ["QuestmasterLogicTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
    ],
    targets: [
        .binaryTarget(
            name: "CGhosttyKitBinary",
            path: "Vendor/GhosttyKit-0.8.0/Vendor/GhosttyKit.xcframework"
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
            name: "QuestmasterCore"
        ),
        .executableTarget(
            name: "Questmaster",
            dependencies: [
                "QuestmasterCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "GhosttyKit",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
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
