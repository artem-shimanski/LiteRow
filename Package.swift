// swift-tools-version: 6.4

import PackageDescription
import CompilerPluginSupport

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
    .enableExperimentalFeature("BorrowingSequence"),
    .enableExperimentalFeature("Lifetimes"),
]

let package = Package(
    name: "LiteRow",
    // iOS is declared for LiteRowUI: without it SwiftPM picks an old default and `@Entry` is unavailable.
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "LiteRow",
            targets: ["LiteRow"]
        ),
        // Database building; only the build-time tool links it.
        .library(
            name: "LiteRowBuild",
            targets: ["LiteRowBuild"]
        ),
        // SwiftUI bridge; kept separate so the core does not depend on a UI framework.
        .library(
            name: "LiteRowUI",
            targets: ["LiteRowUI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .macro(
            name: "LiteRowMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "LiteRow",
            dependencies: ["LiteRowMacros"],
            swiftSettings: swiftSettings,
        ),
        // The only target that writes. Depends on LiteRow for models and schema metadata, never the reverse.
        .target(
            name: "LiteRowBuild",
            dependencies: ["LiteRow"],
            swiftSettings: swiftSettings,
        ),
        .target(
            name: "LiteRowUI",
            dependencies: ["LiteRow"],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "LiteRowTests",
            dependencies: ["LiteRow"],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "LiteRowBuildTests",
            dependencies: ["LiteRowBuild", "LiteRow"],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "LiteRowUITests",
            dependencies: ["LiteRowUI", "LiteRow"],
            swiftSettings: swiftSettings,
        ),
    ]
)
