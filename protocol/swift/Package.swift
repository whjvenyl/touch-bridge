// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TouchBridgeProtocol",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "TouchBridgeProtocol", targets: ["TouchBridgeProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
    ],
    targets: [
        .target(
            name: "TouchBridgeProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "TouchBridgeProtocolTests",
            dependencies: ["TouchBridgeProtocol"]
        ),
    ]
)
