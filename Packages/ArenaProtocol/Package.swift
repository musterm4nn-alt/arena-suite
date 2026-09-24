// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ArenaProtocol",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ArenaAdapter", targets: ["ArenaAdapter"])],
    dependencies: [.package(path: "../ArenaSuiteCore")],
    targets: [
        .target(name: "ArenaAdapter", dependencies: [.product(name: "SuiteDomain", package: "ArenaSuiteCore")]),
        .testTarget(name: "AdapterTests", dependencies: ["ArenaAdapter"]),
    ],
    swiftLanguageModes: [.v6]
)
