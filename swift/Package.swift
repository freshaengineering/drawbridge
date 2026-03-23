// swift-tools-version: 6.0
import PackageDescription

// NOTE: swift-erlang-actor-system is the intended transport for Erlang distribution
// protocol integration. The upstream (otp-interop) uses SSH-only git submodules that
// break CI builds. The dependency is excluded for now — all actor code is stubbed with
// TODO markers showing where ErlangActorSystem integration points go.
//
// EVALUATED (2026-03-23, #23): mbearne-fresha's fork fixes the SSH submodule issue
// by switching .gitmodules to HTTPS URLs. It also adds critical stability fixes:
//   - Non-blocking ei_accept_tmo() accept loop (no thread pool starvation)
//   - Proper socket cleanup on node disconnect (fixes CLOSE_WAIT leak)
//   - Graceful shutdown() method (breaks retain cycles)
//   - Error handling in handleMessage (no more try! crashes)
// dev_proxy uses this fork in production with native Erlang distribution.
// See issue #23 for full evaluation and migration plan.
//
// To enable (when ready to migrate from JSON IPC to Erlang distribution):
//   1. Add: .package(url: "https://github.com/mbearne-fresha/swift-erlang-actor-system", branch: "main")
//   2. Add: .product(name: "ErlangActorSystem", package: "swift-erlang-actor-system") to target deps
//   3. Uncomment `import ErlangActorSystem` in ContainerManager.swift and DrawbridgeAgent.swift
//   4. Replace CommandServer JSON IPC with ErlangActorSystem + distributed actor registration
//   5. CI needs: macos-26 runner, `brew install erlang`, EPMD started before build

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
