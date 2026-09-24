// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CrashHarness",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ArenaSuiteCore")],
    targets: [
        .executableTarget(
            name: "CrashHarness",
            dependencies: [.product(name: "CaptureJournal", package: "ArenaSuiteCore")])
    ],
    swiftLanguageModes: [.v6]
)
