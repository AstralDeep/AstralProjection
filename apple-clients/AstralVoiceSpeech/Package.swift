// swift-tools-version: 6.2
// SwiftPM manifest for AstralVoiceSpeech, the on-device English speech package that runs the Phonon 31m model through FluidAudio.
// FluidAudio is pinned to one commit with only its text-to-speech trait, which leaves out the NeMo and diarization code the voice never uses.
import PackageDescription

let package = Package(
    name: "AstralVoiceSpeech",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AstralVoiceSpeech", targets: ["AstralVoiceSpeech"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "e0c6103bc87a88d25276cad491c86e757f58c865",
            traits: ["TTS"]
        )
    ],
    targets: [
        .target(
            name: "AstralVoiceSpeech",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(
            name: "AstralVoiceSpeechTests",
            dependencies: [
                "AstralVoiceSpeech",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
