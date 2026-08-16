// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Speak2",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.29.0")
    ],
    targets: [
        // Tiny Objective-C shim so AVFAudio's NSException assertions can be caught
        // and surfaced as Swift errors instead of terminating the app.
        .target(
            name: "ObjCExceptionCatcher",
            path: "Support/ObjCExceptionCatcher"
        ),
        .executableTarget(
            name: "Speak2",
            dependencies: [
                "ObjCExceptionCatcher",
                "WhisperKit",
                "FluidAudio",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm")
            ],
            path: "Sources",
            resources: [
                .process("../Resources")
            ]
        ),
        .testTarget(
            name: "Speak2Tests",
            dependencies: ["Speak2"],
            path: "Tests/Speak2Tests"
        )
    ]
)
