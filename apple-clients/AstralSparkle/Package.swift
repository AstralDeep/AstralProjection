// swift-tools-version: 5.9
// SwiftPM manifest for AstralSparkle, the wrapper that hands the exact Sparkle 2.10.1 updater to the AstralApp target.
// Sparkle ships only a macOS slice, so the dependency is conditional and iOS builds link an empty module.
import PackageDescription

let package = Package(
    name: "AstralSparkle",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AstralSparkle", targets: ["AstralSparkle"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(
            name: "AstralSparkle",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
            ]
        )
    ]
)
