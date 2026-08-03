// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FocusBreak",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FocusBreak", targets: ["FocusBreak"]),
        .library(name: "FocusBreakCore", targets: ["FocusBreakCore"])
    ],
    targets: [
        .target(name: "FocusBreakCore"),
        .executableTarget(
            name: "FocusBreak",
            dependencies: ["FocusBreakCore"]
        ),
        .testTarget(
            name: "FocusBreakCoreTests",
            dependencies: ["FocusBreakCore"]
        )
    ]
)
