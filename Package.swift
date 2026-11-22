// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KeyboardHandoff",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "KeyboardHandoff"),
        .testTarget(name: "KeyboardHandoffTests", dependencies: ["KeyboardHandoff"])
    ]
)
