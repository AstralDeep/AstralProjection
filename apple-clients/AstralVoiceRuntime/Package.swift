// swift-tools-version: 5.9
// SwiftPM manifest for AstralVoiceRuntime, the llama.cpp wrapper that runs on-device speech recognition and text generation for the Apple clients.
// Run Scripts/build-voice-runtime.sh first: it writes Artifacts/LlamaRuntime.xcframework, which Git ignores.
import PackageDescription

let package = Package(
    name: "AstralVoiceRuntime",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AstralVoiceRuntime", targets: ["AstralVoiceRuntime"])
    ],
    targets: [
        .binaryTarget(name: "LlamaRuntime", path: "Artifacts/LlamaRuntime.xcframework"),
        .target(
            name: "CAstralLlama",
            dependencies: ["LlamaRuntime"],
            path: "Sources/CAstralLlama",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "AstralVoiceRuntime",
            dependencies: ["CAstralLlama"],
            path: "Sources/AstralVoiceRuntime"
        ),
        .testTarget(
            name: "AstralVoiceRuntimeTests",
            dependencies: ["AstralVoiceRuntime"],
            path: "Tests/AstralVoiceRuntimeTests",
            exclude: ["Fixtures/generate_fixtures.py"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
