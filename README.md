# omsdk-ios-spm

SPM distribution wrapper for the IAB Open Measurement SDK.
IAB doesn't publish OM SDK as an SPM package — it ships as a raw XCFramework per
registered partner. This repo exists solely to host that XCFramework behind a normal
`.package(url:)`.

## Usage

```swift
dependencies: [
    .package(url: "https://github.com/Aniview/omsdk-ios-spm.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "OMSDK_Aniview", package: "omsdk-ios-spm")
        ]
    )
]
```

## Releasing an update

1. Obtain the updated `OMSDK_Aniview.xcframework` (dynamic variant) from the IAB Tech
   Lab tools portal / Aniview partner distribution.
2. `zip -r OMSDK_Aniview.zip OMSDK_Aniview.xcframework`
3. `swift package compute-checksum OMSDK_Aniview.zip`
4. Bump `artifactVersion` in `Package.swift`, update the `checksum`.
5. Tag the release and upload `OMSDK_Aniview.zip` as a release asset at a
   URL matching what's in `Package.swift`.

## License

Distribution of OM SDK is governed by IAB's OM SDK license terms (see `OMLICENSE` in the
original download) — this repo only repackages the binary for SPM consumption.
