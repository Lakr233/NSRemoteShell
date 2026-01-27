// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NSRemoteShell",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(
            name: "NSRemoteShell",
            targets: ["NSRemoteShell"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libssh2-spm", from: "2.0.3"),
    ],
    targets: [
        .target(
            name: "NSRemoteShell",
            dependencies: [
                .product(name: "CSSH2", package: "libssh2-spm"),
            ]
        ),
        .testTarget(
            name: "NSRemoteShellTests",
            dependencies: [
                "NSRemoteShell",
            ]
        ),
    ]
)
