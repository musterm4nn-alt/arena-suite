// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ArenaSuiteCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SuiteDomain", targets: ["SuiteDomain"]),
        .library(name: "ApplicationActions", targets: ["ApplicationActions"]),
        .library(name: "CaptureJournal", targets: ["CaptureJournal"]),
    ],
    targets: [
        .target(name: "SuiteDomain"),
        .target(name: "ApplicationActions", dependencies: ["SuiteDomain", "CaptureJournal"]),
        .target(name: "CaptureJournal"),
        .testTarget(name: "SuiteDomainTests", dependencies: ["SuiteDomain", "ApplicationActions", "CaptureJournal"]),
        .testTarget(name: "CaptureJournalTests", dependencies: ["CaptureJournal"]),
    ],
    swiftLanguageModes: [.v6]
)
