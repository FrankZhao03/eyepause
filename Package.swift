// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EyePause",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EyePause", targets: ["EyePause"])
    ],
    targets: [
        .executableTarget(name: "EyePause")
    ]
)
