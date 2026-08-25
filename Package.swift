// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tokenia-proxy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokeniaProxy", targets: ["TokeniaProxy"]),
        .library(name: "TokeniaCore", targets: ["TokeniaCore"]),
    ],
    targets: [
        .target(name: "TokeniaCore"),
        .target(name: "TokeniaProxy", dependencies: ["TokeniaCore"]),
        .target(name: "TokeniaTestSupport"),
        .executableTarget(
            name: "tokenia-stress",
            dependencies: ["TokeniaProxy", "TokeniaTestSupport"]
        ),
        .testTarget(
            name: "TokeniaProxyTests",
            dependencies: ["TokeniaProxy", "TokeniaTestSupport"]
        ),
    ]
)
