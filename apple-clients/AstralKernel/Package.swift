// swift-tools-version: 5.9
// SwiftPM manifest for the Swift wrapper around the shared Rust kernel. Run AstralKernel's scripts/build-apple.sh first: it writes Artifacts/, which holds the xcframework and the generated bindings and is never committed.
import PackageDescription

let package = Package(
    name: "AstralKernel",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AstralKernel", targets: ["AstralKernel"])
    ],
    targets: [
        .binaryTarget(name: "AstralKernelFFI", path: "Artifacts/AstralKernelFFI.xcframework"),
        .target(
            name: "AstralKernelBindings",
            dependencies: ["AstralKernelFFI"],
            path: "Artifacts/Bindings",
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
            ]
        ),
        .target(
            name: "AstralKernel",
            dependencies: ["AstralKernelBindings"],
            path: "Sources/AstralKernel"
        ),
        .testTarget(
            name: "AstralKernelTests",
            dependencies: ["AstralKernel"],
            path: "Tests/AstralKernelTests"
        ),
    ]
)
