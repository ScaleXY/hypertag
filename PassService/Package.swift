// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "PassService",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pass-service", targets: ["pass-service"])
    ],
    dependencies: [
        // Pinned by revision: apple/pass-builder has no tags yet, and its API is an early preview.
        .package(url: "https://github.com/apple/pass-builder.git", revision: "6138535e09456652f7a98c167dbdca361672ae1a"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.36.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.1"),
    ],
    targets: [
        .target(
            name: "PassServiceCore",
            dependencies: [
                .product(name: "PassBuilder", package: "pass-builder"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            resources: [
                .embedInCode("Resources/icon.png"),
                .embedInCode("Resources/icon@2x.png"),
                .embedInCode("Resources/logo.png"),
            ]
        ),
        .executableTarget(name: "pass-service", dependencies: ["PassServiceCore"]),
        .testTarget(
            name: "PassServiceTests",
            dependencies: [
                "PassServiceCore",
                "pass-service",
                .product(name: "PassBuilder", package: "pass-builder"),
            ]
        ),
    ]
)
