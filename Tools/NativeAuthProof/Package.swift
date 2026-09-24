// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "NativeAuthProof",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NativeAuthProof", targets: ["NativeAuthProof"]),
        .library(name: "NativeAuthResearch", targets: ["NativeAuthResearch"]),
    ],
    targets: [
        .target(name: "NativeAuthResearch"),
        .executableTarget(name: "NativeAuthProof", dependencies: ["NativeAuthResearch"]),
        .testTarget(name: "NativeAuthResearchTests", dependencies: ["NativeAuthResearch"]),
    ],
    swiftLanguageModes: [.v6]
)
