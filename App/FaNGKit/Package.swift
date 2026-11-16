// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FaNGKit",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: [
        .library(name: "FaNGKit", targets: ["FaNGKit"]),
    ],
    dependencies: [
        // Vendored AMSMB2 4.0.3 with two additions; see Vendor/AMSMB2/FANG-PATCHES.md.
        .package(path: "../Vendor/AMSMB2"),
    ],
    targets: [
        .target(
            name: "FaNGKit",
            dependencies: [
                .product(name: "AMSMB2", package: "AMSMB2"),
            ]
        ),
        .testTarget(name: "FaNGKitTests", dependencies: ["FaNGKit"]),
    ]
)
