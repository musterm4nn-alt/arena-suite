// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ArenaSuiteCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SuiteDomain", targets: ["SuiteDomain"]),
        .library(name: "ApplicationActions", targets: ["ApplicationActions"]),
    ],
    targets: [
        .target(name: "SuiteDomain"),
        .target(name: "ApplicationActions", dependencies: ["SuiteDomain"]),
        .testTarget(name: "SuiteDomainTests", dependencies: ["SuiteDomain", "ApplicationActions"]),
    ],
    swiftLanguageModes: [.v6]
)
