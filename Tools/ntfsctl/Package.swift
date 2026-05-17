// swift-tools-version: 6.0
// ntfsctl — command-line companion to NTFSCore. Operates on raw devices
// (and disk-image files) without needing the FSKit extension to be active.

import PackageDescription

let package = Package(
    name: "ntfsctl",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ntfsctl", targets: ["ntfsctl"])
    ],
    dependencies: [
        .package(path: "../../Packages/NTFSCore"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "ntfsctl",
            dependencies: [
                "NTFSCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
