// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FlutterSkill",
    platforms: [
        .iOS(.v14),
    ],
    products: [
        .library(
            name: "FlutterSkill",
            targets: ["FlutterSkill"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "FlutterSkill",
            dependencies: [],
            path: "Sources/FlutterSkill",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "FlutterSkillTests",
            dependencies: ["FlutterSkill"],
            path: "Tests/FlutterSkillTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
