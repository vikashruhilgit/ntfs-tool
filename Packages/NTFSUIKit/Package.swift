// swift-tools-version: 6.0
// NTFSUIKit — shared SwiftUI design-system layer (tokens + reusable components +
// pure view-model mappers) consumed by the NTFS Mount Manager menu-bar and main
// window. Contains NO NTFS parsing logic of its own: it depends on NTFSCore only
// for the public Sendable value types it maps into display fields.

import PackageDescription

let package = Package(
    name: "NTFSUIKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "NTFSUIKit", targets: ["NTFSUIKit"])
    ],
    dependencies: [
        .package(path: "../NTFSCore"),
        .package(path: "../NTFSOps")
    ],
    targets: [
        .target(
            name: "NTFSUIKit",
            dependencies: [
                .product(name: "NTFSCore", package: "NTFSCore"),
                .product(name: "NTFSOps", package: "NTFSOps")
            ],
            resources: [
                .process("Resources/NTFSColors.xcassets")
            ]
        ),
        .testTarget(
            name: "NTFSUIKitTests",
            dependencies: ["NTFSUIKit"]
        )
    ]
)
