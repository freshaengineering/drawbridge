// swift-tools-version: 6.0
import PackageDescription

// NOTE: swift-erlang-actor-system is the intended transport for Erlang distribution
// protocol integration. It's currently pre-alpha with SSH-only submodules that break
// CI builds. The dependency is excluded for now — all actor code is stubbed with
// TODO markers showing where ErlangActorSystem integration points go.
//
// To enable locally:
//   1. Add: .package(url: "https://github.com/otp-interop/swift-erlang-actor-system.git", branch: "main")
//   2. Add: .product(name: "ErlangActorSystem", package: "swift-erlang-actor-system") to target deps
//   3. Uncomment `import ErlangActorSystem` in ContainerManager.swift and DrawbridgeAgent.swift

let package = Package(
    name: "DrawbridgeAgent",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "DrawbridgeAgent",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
