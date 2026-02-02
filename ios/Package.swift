// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TetherlySDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TetherlySDK",
            targets: ["TetherlySDK"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "125.0.0"),
    ],
    targets: [
        .target(
            name: "TetherlySDK",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources/TetherlySDK"
        ),
    ]
)
