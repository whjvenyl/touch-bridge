// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TouchBridgeDaemon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "touchbridge", targets: ["touchbridge"]),
        .library(name: "TouchBridgeCore", targets: ["TouchBridgeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(path: "../../protocol/swift"),
    ],
    targets: [
        .target(
            name: "TouchBridgeCore",
            dependencies: [
                .product(name: "TouchBridgeProtocol", package: "swift"),
            ]
        ),
        .executableTarget(
            name: "touchbridge",
            dependencies: [
                "TouchBridgeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "TouchBridgeCoreTests",
            dependencies: ["TouchBridgeCore"]
        ),
    ]
)
