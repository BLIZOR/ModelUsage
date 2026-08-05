// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ModelUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ModelUsage", path: "Sources/ModelUsage")
    ]
)
