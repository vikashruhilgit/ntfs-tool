// swift-tools-version: 6.0
// NTFSOps — the shared file-operation engine (copy / move / delete) that sits
// between NTFSCore and the two front-ends. `ntfsctl cp` / `rm` and the menu-bar
// app's file browser both drive THIS engine, so the copy semantics that Windows
// `chkdsk` validated at v0.7.4 exist exactly once in the codebase.
//
// Contains no UI and no argument parsing: progress is reported through a
// callback, cancellation through standard Swift task cancellation.

import PackageDescription

let package = Package(
    name: "NTFSOps",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NTFSOps", targets: ["NTFSOps"])
    ],
    dependencies: [
        .package(path: "../NTFSCore")
    ],
    targets: [
        .target(
            name: "NTFSOps",
            dependencies: [
                .product(name: "NTFSCore", package: "NTFSCore")
            ]
        ),
        .testTarget(
            name: "NTFSOpsTests",
            dependencies: [
                "NTFSOps",
                .product(name: "NTFSCore", package: "NTFSCore")
            ]
        )
    ]
)
