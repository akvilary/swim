// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Swim",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Swim",
            path: "Sources/Swim"
        )
    ]
)
