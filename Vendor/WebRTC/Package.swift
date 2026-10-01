// swift-tools-version:5.3
//
// Local checksum-pinned package for the stasel/WebRTC M151 binary.
//
// The upstream Swift package tag 151.0.0 references
//   releases/download/151.0.0/WebRTC-M151.xcframework.zip
// which GitHub currently answers with 404; the byte-identical M151 binary was
// republished under release tag 151.0.1 (same asset name, same digest). To
// keep the exact pinned WebRTC 151.0.0 binary — rather than silently move to a
// newer release — Scripts/bootstrap.sh downloads the M151 asset, verifies the
// digest below and extracts WebRTC.xcframework next to this file.
//
// Verified Swift Package Manager checksum (== SHA-256 of the zip):
//   6f3f5693383ce65763190c46ca9f2c4325c34b83681acb9db30f01488e15f1e0
import PackageDescription

let package = Package(
    name: "WebRTC",
    products: [
        .library(name: "WebRTC", targets: ["WebRTC"])
    ],
    targets: [
        .binaryTarget(name: "WebRTC", path: "WebRTC.xcframework")
    ]
)
