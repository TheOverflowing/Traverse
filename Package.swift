// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Traverse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Traverse", targets: ["TraverseApp"]),
        .executable(name: "traverse-cli", targets: ["TraverseCLI"]),
        .executable(name: "TraverseLauncher", targets: ["TraverseLauncher"]),
    ],
    targets: [
        .target(name: "TraverseCore", resources: [.copy("Resources")]),
        .executableTarget(name: "TraverseApp", dependencies: ["TraverseCore"]),
        .executableTarget(name: "TraverseCLI", dependencies: ["TraverseCore"]),
        .executableTarget(name: "TraverseLauncher"),
    ]
)
