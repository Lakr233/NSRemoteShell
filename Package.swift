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
    targets: [
        .target(
            name: "NSRemoteShell",
            dependencies: ["CSSH"]
        ),
        .binaryTarget(name: "CSSH", path: "External/CSSH.xcframework")
    ]
)
