// swift-tools-version: 5.5

import PackageDescription

let package = Package(
    name: "NSRemoteShell",
    products: [
        .library(
            name: "NSRemoteShell",
            targets: ["NSRemoteShell"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libssh2-spm", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "NSRemoteShell",
            dependencies: [
                .product(name: "CSSH2", package: "libssh2-spm"),
            ]
        ),
    ]
)
