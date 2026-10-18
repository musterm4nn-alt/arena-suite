// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ArenaSuiteCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SuiteDomain", targets: ["SuiteDomain"]),
        .library(name: "ApplicationActions", targets: ["ApplicationActions"]),
        .library(name: "CaptureJournal", targets: ["CaptureJournal"]),
        .library(name: "ArchiveIndex", targets: ["ArchiveIndex"]),
    ],
    dependencies: [
        // Pinned in Phase 0 (Tools/DependencyProbe): 7.11.1 = b83108d10f42680d78f23fe4d4d80fc88dab3212.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(name: "SuiteDomain"),
        .target(name: "CaptureJournal"),
        // Rebuildable SQLite projection (plan v3 §10). GRDB stays behind this module's typed API.
        .target(name: "ArchiveIndex", dependencies: ["SuiteDomain", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "ApplicationActions", dependencies: ["SuiteDomain", "CaptureJournal", "ArchiveIndex"]),
        .testTarget(name: "SuiteDomainTests", dependencies: ["SuiteDomain", "ApplicationActions", "CaptureJournal"]),
        .testTarget(name: "CaptureJournalTests", dependencies: ["CaptureJournal"]),
        .testTarget(name: "ArchiveIndexTests", dependencies: ["ArchiveIndex", "SuiteDomain", "ApplicationActions", "CaptureJournal"]),
        .testTarget(name: "DatasetTests", dependencies: ["ApplicationActions", "ArchiveIndex", "SuiteDomain", "CaptureJournal"]),
    ],
    swiftLanguageModes: [.v6]
)
