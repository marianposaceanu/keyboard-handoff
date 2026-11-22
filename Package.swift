// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyboardHandoff",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "KeyboardHandoff", path: ".", exclude: [
            "KeyboardHandoff", "Tests", "scripts", "Info.plist", "build.sh", "test.sh", "README.md"
        ], sources: ["Core", "Shared"]),
        .testTarget(name: "KeyboardHandoffTests", dependencies: ["KeyboardHandoff"])
    ]
)
