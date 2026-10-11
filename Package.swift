// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FastShare",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FastShareCore"),
        .executableTarget(name: "FastShare", dependencies: ["FastShareCore"]),
        .testTarget(name: "FastShareCoreTests", dependencies: ["FastShareCore"]),
    ]
)
