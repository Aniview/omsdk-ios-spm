// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

private let artifactVersion = "1.0.0"

let package = Package(
    name: "omsdk-ios-spm",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "OMSDK_Aniview",
            targets: ["OMSDK_Aniview"]
        ),
        // Ergonomic Swift wrapper around OMSDK_Aniview.
        .library(
            name: "OMSDKKit",
            targets: ["OMSDKKit"]
        )
    ],
    targets: [
        // Wraps the IAB Open Measurement SDK as a proper SPM binary target.
        // IAB doesn't publish OM SDK as an SPM package itself — it's
        // distributed as a raw XCFramework — so this repo exists purely to host that
        // XCFramework behind a normal .package(url:) dependency.
        .binaryTarget(
            name: "OMSDK_Aniview",
            url: "https://github.com/Aniview/omsdk-ios-spm/releases/download/v\(artifactVersion)/OMSDK_Aniview.zip",
            checksum: "cdd7bdc60556aafd745ed1c0b7e94d76dd8647f66c9a3eebb846c371c5a87256"
        ),
        .target(
            name: "OMSDKKit",
            dependencies: ["OMSDK_Aniview"]
        )
    ]
)
