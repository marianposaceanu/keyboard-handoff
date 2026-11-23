// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyboardHandoff",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "KeyboardHandoff", path: ".", exclude: [
            "KeyboardHandoff", "Tests", "scripts", "docs", "Info.plist",
            "build.sh", "test.sh", "README.md", "CONTRIBUTING.md", "RELEASING.md"
        ], sources: ["Core", "Shared"]),
        .testTarget(name: "KeyboardHandoffTests", dependencies: ["KeyboardHandoff"])
    ]
)
