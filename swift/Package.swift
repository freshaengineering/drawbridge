// swift-tools-version: 6.0
import PackageDescription

// NOTE: swift-erlang-actor-system is pre-alpha and may not resolve automatically.
// If `swift package resolve` fails, you may need to manually check out:
//   https://github.com/otp-interop/swift-erlang-actor-system
// and use `.package(path: "../swift-erlang-actor-system")` instead.

let package = Package(
    name: "DrawbridgeAgent",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/otp-interop/swift-erlang-actor-system.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "DrawbridgeAgent",
            dependencies: [
                .product(name: "ErlangActorSystem", package: "swift-erlang-actor-system"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
