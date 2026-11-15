// swift-tools-version: 5.9
// SwiftPM manifest for AstralVoiceModel, the on-device LFM3-Audio runtime built on MLX Swift.
// The Apple app links it for speech recognition, speech synthesis and short replies, and its tests run with xcodebuild because MLX's Metal shaders need Xcode.
import PackageDescription

let package = Package(
    name: "AstralVoiceModel",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AstralVoiceModel", targets: ["AstralVoiceModel"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0")
    ],
    targets: [
        .target(
            name: "AstralVoiceModel",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),
        .testTarget(
            name: "AstralVoiceModelTests",
            dependencies: ["AstralVoiceModel"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
