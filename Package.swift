// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Swim",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure, dependency-free modules shared by the app and the tests.
        .target(
            name: "SwimCore",
            path: "Sources/SwimCore"
        ),
        .executableTarget(
            name: "Swim",
            dependencies: ["SwimCore"],
            path: "Sources/Swim"
        ),
        .testTarget(
            name: "SwimCoreTests",
            dependencies: ["SwimCore"],
            path: "Tests/SwimCoreTests"
        ),
    ]
)
