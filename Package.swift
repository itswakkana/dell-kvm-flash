// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DellKVMFlash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DellKVMFlash", path: "Sources/DellKVMFlash")
    ]
)
