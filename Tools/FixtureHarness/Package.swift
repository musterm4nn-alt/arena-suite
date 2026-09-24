// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FixtureHarness",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TransportProbe", targets: ["TransportProbe"])],
    dependencies: [.package(path: "../NativeAuthProof"), .package(path: "../../Packages/ArenaProtocol")],
    targets: [
        .executableTarget(
            name: "TransportProbe",
            dependencies: [
                .product(name: "NativeAuthResearch", package: "NativeAuthProof"),
                .product(name: "FoundationTransport", package: "ArenaProtocol"),
            ])
    ],
    swiftLanguageModes: [.v6]
)
