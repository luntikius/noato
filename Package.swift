// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "quill",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        // CommandLineTools does not bundle the Testing module. Pin it to the
        // matching toolchain release so `swift test` also works without a full
        // Xcode installation.
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.3-RELEASE"
        ),
    ],
    targets: [
        .executableTarget(
            name: "quill",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary so TCC can attribute the
                // system-audio-capture permission to quill itself when it
                // runs as a LaunchAgent (no .app bundle to carry a plist).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/quill/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "quillTests",
            dependencies: [
                "quill",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
