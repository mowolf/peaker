// swift-tools-version: 6.2
import PackageDescription

// Platform-independent core of Peaker: geo maths, tile decoding, horizon/ridge engine,
// projection and label layout. No UIKit/CoreLocation here, so it builds and tests on
// macOS and Linux (`swift test`).
let package = Package(
    name: "PeakerKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "PeakerKit", targets: ["PeakerKit"]),
    ],
    targets: [
        .target(name: "PeakerKit"),
        .testTarget(name: "PeakerKitTests", dependencies: ["PeakerKit"]),
    ]
)
