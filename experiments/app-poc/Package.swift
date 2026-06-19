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
        .executableTarget(
            name: "QuestmasterAppPoc",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
