// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AINotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AINotch",
            path: "Sources/AINotch"
        )
    ]
)
