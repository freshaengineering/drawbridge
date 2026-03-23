import Foundation

// TODO: When swift-erlang-actor-system resolves, replace `actor` with:
//   @StableNames
//   distributed actor ContainerManager {
//       typealias ActorSystem = ErlangActorSystem
//   }
// and annotate each method with @StableName("snake_case_name")

/// Manages container lifecycle. Designed to become a distributed actor
/// over Erlang distribution via swift-erlang-actor-system.
///
/// Erlang-side interface (stable names):
///   start_container/4  -> startContainer(name:image:ports:env:)
///   stop_container/1   -> stopContainer(name:)
///   pull_image/1       -> pullImage(image:)
///   container_status/1 -> containerStatus(name:)
///   list_containers/0  -> listContainers()
actor ContainerManager {

    private let runtime = ContainerRuntime()
    private var containers: [String: ContainerInfo] = [:]

    init() {}

    /// Reconcile local state with Apple Container on startup.
    func reconcile() async {
        do {
            let live = try await runtime.list()
            for info in live {
                containers[info.name] = info
            }
            print("[ContainerManager] Reconciled \(live.count) container(s)")
        } catch {
            print("[ContainerManager] Reconcile failed: \(error)")
        }
    }

    // MARK: - Distributed interface

    // @StableName("start_container")
    func startContainer(
        name: String,
        image: String,
        ports: [[String: Int]],
        env: [String: String],
        onPullProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ContainerInfo {
        let mappings = ports.compactMap { d -> PortMapping? in
            guard let h = d["host"], let c = d["container"] else { return nil }
            return PortMapping(hostPort: h, containerPort: c)
        }

        // Pull first (with progress streaming) so `container run` doesn't block on pull
        print("[ContainerManager] \(name): step 1/3 — checking if image needs pull")
        if let onProgress = onPullProgress {
            print("[ContainerManager] \(name): step 1/3 — pulling \(image) (with progress)")
            try await runtime.pullStreaming(image: image, onLine: onProgress)
        } else {
            print("[ContainerManager] \(name): step 1/3 — pulling \(image)")
            try await runtime.pull(image: image)
        }
        print("[ContainerManager] \(name): step 1/3 — pull complete")

        // Remove stale container if it exists (e.g. from a previous crashed run)
        if let existing = try? await runtime.inspect(name: name) {
            print("[ContainerManager] \(name): removing stale container (state=\(existing.state.rawValue))")
            try? await runtime.remove(name: name)
        }

        print("[ContainerManager] \(name): step 2/3 — starting container (ports: \(mappings.map { "\($0.hostPort):\($0.containerPort)" }))")
        var info = try await runtime.run(name: name, image: image, ports: mappings, env: env)
        print("[ContainerManager] \(name): step 2/3 — container started, state=\(info.state.rawValue)")

        info.state = .booting
        containers[name] = info
        print("[ContainerManager] \(name): step 3/3 — registered, returning to bridge")
        return info
    }

    // @StableName("stop_container")
    func stopContainer(name: String) async throws -> Bool {
        try await runtime.stop(name: name)
        containers[name]?.state = .stopped
        return true
    }

    // @StableName("pull_image")
    func pullImage(image: String) async throws -> Bool {
        try await runtime.pull(image: image)
        return true
    }

    /// Pull image while streaming progress lines via a callback.
    func pullImageStreaming(image: String, onLine: @Sendable @escaping (String) -> Void) async throws -> Bool {
        try await runtime.pullStreaming(image: image, onLine: onLine)
        return true
    }

    // @StableName("container_status")
    func containerStatus(name: String) async -> ContainerState {
        // Refresh from runtime if we have a record
        if containers[name] != nil {
            if let fresh = try? await runtime.inspect(name: name) {
                containers[name] = fresh
                return fresh.state
            }
        }
        return containers[name]?.state ?? .notPulled
    }

    // @StableName("list_containers")
    func listContainers() async -> [ContainerInfo] {
        // Refresh from runtime
        if let live = try? await runtime.list() {
            for info in live { containers[info.name] = info }
        }
        return Array(containers.values)
    }
}
