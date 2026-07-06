// swift-tools-version:6.0
import PackageDescription

// Local MLX Whisper STT engine. The Whisper implementation is vendored from
// mlx-audio-swift (https://github.com/Blaizzy/mlx-audio-swift, MIT — see
// LICENSE-mlx-audio-swift) at commit 580e952adda0cd6bdc5c04f402822adbb61525c8
// (2026-07-03), trimmed to the Whisper model only so the app does not compile
// the 18 other STT families, the codecs, or mlx-swift-lm. Local changes on
// top of upstream: initial-prompt (`<|startofprev|>`) support so the user
// vocabulary reaches the decoder, and a downloader with real progress
// reporting instead of prints.
let package = Package(
    name: "MLXWhisper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MLXWhisper", targets: ["MLXWhisper"]),
        // Terminal bench/QA runner: XCTest-host numbers are not
        // representative for the GPU path, so STT evidence comes from here.
        .executable(name: "mlxwhisper-cli", targets: ["mlxwhisper-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMajor(from: "1.1.6")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMajor(from: "0.8.1")),
    ],
    targets: [
        .target(
            name: "MLXWhisper",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/MLXWhisper"
        ),
        .executableTarget(
            name: "mlxwhisper-cli",
            dependencies: ["MLXWhisper"],
            path: "Sources/mlxwhisper-cli"
        ),
    ]
)
