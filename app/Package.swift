// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QuestmasterAppPoc",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "QuestmasterAppPoc", targets: ["QuestmasterAppPoc"]),
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
            name: "QuestmasterAppPocCore"
        ),
        .executableTarget(
            name: "QuestmasterAppPoc",
            dependencies: [
                "QuestmasterAppPocCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "GhosttyKit",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(
            name: "QuestmasterAppPocLogicTests",
            dependencies: [
                "QuestmasterAppPocCore",
            ],
            path: "Tests/QuestmasterAppPocLogicTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
