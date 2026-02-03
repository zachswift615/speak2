// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Speak2",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9")
    ],
    targets: [
        .executableTarget(
            name: "Speak2",
            dependencies: ["WhisperKit", "FluidAudio"],
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
