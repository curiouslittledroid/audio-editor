// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudioEditor",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "AudioEditor",
            path: "Sources/AudioEditor"
        )
    ]
)
