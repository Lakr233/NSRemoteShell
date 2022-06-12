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
        .package(url: "https://github.com/DimaRU/Libssh2Prebuild.git", branch: "1.10.0+OpenSSL_1_1_1o"),
    ],
    targets: [
        .target(
            name: "NSRemoteShell",
            dependencies: [
                .product(name: "CSSH", package: "Libssh2Prebuild"),
            ]
        ),
    ]
)
