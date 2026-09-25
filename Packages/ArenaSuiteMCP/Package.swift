// swift-tools-version: 6.1
import PackageDescription

// Read-only MCP server over the local archive (plan v3 §14). Depends on ArenaSuiteCore only: it
// cannot reach ArenaAdapter, FoundationTransport or any network code. Tests use ArenaAdapter's
// decoder solely to build fixture indexes.
let package = Package(
    name: "ArenaSuiteMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "arena-suite-mcp", targets: ["arena-suite-mcp"]),
        .library(name: "ArchiveMCP", targets: ["ArchiveMCP"]),
    ],
    dependencies: [
        .package(path: "../ArenaSuiteCore"),
        .package(path: "../ArenaProtocol"),
    ],
    targets: [
        .target(
            name: "ArchiveMCP",
            dependencies: [
                .product(name: "SuiteDomain", package: "ArenaSuiteCore"),
                .product(name: "ApplicationActions", package: "ArenaSuiteCore"),
                .product(name: "ArchiveIndex", package: "ArenaSuiteCore"),
            ]),
        .executableTarget(name: "arena-suite-mcp", dependencies: ["ArchiveMCP"]),
        .testTarget(
            name: "ArchiveMCPTests",
            dependencies: [
                "ArchiveMCP",
                .product(name: "SuiteDomain", package: "ArenaSuiteCore"),
                .product(name: "ApplicationActions", package: "ArenaSuiteCore"),
                .product(name: "ArchiveIndex", package: "ArenaSuiteCore"),
                .product(name: "CaptureJournal", package: "ArenaSuiteCore"),
                .product(name: "ArenaAdapter", package: "ArenaProtocol"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
