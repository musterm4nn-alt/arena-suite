// swift-tools-version: 6.1
import PackageDescription

// Phase 0 build probe only; these packages are not linked into the application yet.
let package = Package(
    name: "DependencyProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .executableTarget(
            name: "DependencyProbe",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MCP", package: "swift-sdk"),
            ])
    ],
    swiftLanguageModes: [.v6]
)
