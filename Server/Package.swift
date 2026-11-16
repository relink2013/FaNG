// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FaNG-Server",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "fang-api", targets: ["fang-api"]),
        .executable(name: "fang-storaged", targets: ["fang-storaged"]),
        .executable(name: "fang-thumbs", targets: ["fang-thumbs"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "FaNGCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "fang-api",
            dependencies: [
                "FaNGCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(name: "CLinuxFS"),
        .executableTarget(
            name: "fang-storaged",
            dependencies: [
                "FaNGCore",
                "CLinuxFS",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .executableTarget(
            name: "fang-thumbs",
            dependencies: [
                "FaNGCore",
                "CLinuxFS",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "FaNGCoreTests", dependencies: ["FaNGCore"]),
    ]
)
