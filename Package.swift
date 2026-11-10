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
        // The app module's window-level wiring: the jump/reveal
        // doctrines through the real EditorWindow (headless — the
        // tests never touch the terminal; Application-level glue stays
        // on the manual checklist). The executable's entry point is
        // main.swift, the shape SwiftPM needs to build a testable
        // variant of an executable target.
        .testTarget(
            name: "SwimTests",
            dependencies: ["Swim"],
            path: "Tests/SwimTests"
        ),
    ]
)
