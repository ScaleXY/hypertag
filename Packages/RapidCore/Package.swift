// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "RapidCore",
    platforms: [.iOS("18.2"), .macOS(.v15)],
    products: [
        .library(name: "TagEngine", targets: ["TagEngine"]),
        .library(name: "SignerCore", targets: ["SignerCore"]),
        .library(name: "TagStore", targets: ["TagStore"]),
        .library(name: "EmulationKit", targets: ["EmulationKit"]),
        .library(name: "WalletBridge", targets: ["WalletBridge"]),
    ],
    dependencies: [
        // We only call recovery, but under Xcode P256K compiles its Swift for every module (`#if Xcode || ...`),
        // so an app fails to link unless the C code for ecdh and musig (which implies schnorrsig) is built too.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.24.0", traits: ["ecdh", "musig", "recovery"]),
    ],
    targets: [
        .target(name: "TagEngine"),
        .target(
            name: "SignerCore",
            dependencies: [
                "TagEngine",
                .product(name: "P256K", package: "swift-secp256k1"),
                // Secret-touching calls go straight to C so the key never passes through a Swift Array or Data.
                .product(name: "libsecp256k1", package: "swift-secp256k1"),
            ]
        ),
        .target(name: "TagStore", dependencies: ["TagEngine", "SignerCore"]),
        .target(name: "EmulationKit", dependencies: ["TagEngine"]),
        .target(name: "WalletBridge"),
        .testTarget(name: "TagEngineTests", dependencies: ["TagEngine"]),
        .testTarget(name: "SignerCoreTests", dependencies: ["SignerCore"], resources: [.copy("Resources")]),
        .testTarget(name: "TagStoreTests", dependencies: ["TagStore"]),
        .testTarget(name: "EmulationKitTests", dependencies: ["EmulationKit"]),
        .testTarget(name: "WalletBridgeTests", dependencies: ["WalletBridge"]),
    ]
)
