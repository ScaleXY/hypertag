// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ReaderHarness",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/RapidCore"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.24.0", traits: ["ecdh", "musig", "recovery"]),
    ],
    targets: [
        .executableTarget(
            name: "ReaderHarness",
            dependencies: [
                .product(name: "TagEngine", package: "RapidCore"),
                .product(name: "SignerCore", package: "RapidCore"),
                .product(name: "P256K", package: "swift-secp256k1"),
            ]
        ),
    ]
)
