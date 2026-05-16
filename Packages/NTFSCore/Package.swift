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
            dependencies: ["NTFSCore"],
            // Fixtures are loaded directly via #filePath; declaring them as
            // resources would force Bundle.module lookups that don't work
            // identically across `swift test` and Xcode-driven test runs.
            exclude: ["Fixtures"]
        )
    ]
)
