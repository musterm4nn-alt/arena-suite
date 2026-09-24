// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ArenaProtocol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArenaAdapter", targets: ["ArenaAdapter"]),
        .library(name: "FoundationTransport", targets: ["FoundationTransport"]),
    ],
    dependencies: [.package(path: "../ArenaSuiteCore")],
    targets: [
        // Arena-agnostic: per-account URLSession, bounded capture, cookie persistence.
        .target(name: "FoundationTransport"),
        // The only module that knows Arena routes (plan v3 §5, §16).
        .target(
            name: "ArenaAdapter",
            dependencies: [
                "FoundationTransport",
                .product(name: "SuiteDomain", package: "ArenaSuiteCore"),
                .product(name: "ApplicationActions", package: "ArenaSuiteCore"),
                .product(name: "CaptureJournal", package: "ArenaSuiteCore"),
            ]),
        .testTarget(
            name: "AdapterTests",
            dependencies: [
                "ArenaAdapter", "FoundationTransport", .product(name: "CaptureJournal", package: "ArenaSuiteCore"),
                .product(name: "ApplicationActions", package: "ArenaSuiteCore"),
                .product(name: "ArchiveIndex", package: "ArenaSuiteCore"),
            ]),
        .testTarget(name: "TransportTests", dependencies: ["FoundationTransport"]),
    ],
    swiftLanguageModes: [.v6]
)
