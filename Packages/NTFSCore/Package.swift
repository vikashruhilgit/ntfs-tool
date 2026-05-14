// swift-tools-version: 6.0
// NTFSCore — clean-room NTFS reader/writer in Swift for macOS FSKit-based tooling.

import PackageDescription

let package = Package(
    name: "NTFSCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "NTFSCore", targets: ["NTFSCore"])
    ],
    targets: [
        .target(name: "NTFSCore"),
        .testTarget(
            name: "NTFSCoreTests",
            dependencies: ["NTFSCore"]
        )
    ]
)
