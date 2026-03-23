import Foundation

/// Thin wrapper around the `container` CLI tool shipped with Apple Container.
/// All operations shell out to `container` and parse its JSON/text output.
actor ContainerRuntime {

    // MARK: - Public API

    func pull(image: String) async throws {
        let (_, stderr, code) = try await runCommand(["image", "pull", image])
        guard code == 0 else {
            throw RuntimeError.commandFailed("pull \(image): \(stderr)")
        }
    }

    /// Pull an image while streaming progress lines to a callback.
    /// The callback receives each stdout line as it arrives. Returns when the pull completes.
    func pullStreaming(image: String, onLine: @Sendable @escaping (String) -> Void) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["container", "image", "pull", image]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        // Read stdout line-by-line on a detached task
        let fileHandle = outPipe.fileHandleForReading
        let readTask = Task.detached {
            var buffer = Data()
            let newline = UInt8(ascii: "\n")
            while true {
                let chunk = fileHandle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                // Emit complete lines
                while let idx = buffer.firstIndex(of: newline) {
                    let lineData = buffer[buffer.startIndex..<idx]
                    buffer = Data(buffer[(idx + 1)...])
                    if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !line.isEmpty {
                        onLine(line)
                    }
                }
            }
            // Emit any trailing content
            if !buffer.isEmpty,
               let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                onLine(line)
            }
        }

        proc.waitUntilExit()
        _ = await readTask.value

        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            throw RuntimeError.commandFailed("pull \(image): \(stderr)")
        }
    }

    func run(
        name: String,
        image: String,
        ports: [PortMapping],
        env: [String: String],
        cpus: Double? = nil,
        memory: String? = nil
    ) async throws -> ContainerInfo {
        var args = ["run", "-d", "--name", name]

        // No port mapping — containers get their own IP on the NAT network
        // and drawbridge connects to container-ip:container-port directly.
        for (k, v) in env {
            args += ["-e", "\(k)=\(v)"]
        }
        if let cpus { args += ["--cpus", String(cpus)] }
        if let memory { args += ["--memory", memory] }
        args.append(image)

        let portDesc = ports.map { "\($0.hostPort):\($0.containerPort)" }.joined(separator: ", ")
        print("[ContainerRuntime] \(name): running `container \(args.prefix(4).joined(separator: " "))...` ports=[\(portDesc)] env_count=\(env.count)")

        let (stdout, stderr, code) = try await runCommand(args)
        if code == 0 {
            print("[ContainerRuntime] \(name): container started (id=\(stdout.prefix(12).trimmingCharacters(in: .whitespacesAndNewlines)))")
        } else {
            print("[ContainerRuntime] \(name): run failed (exit \(code)): \(stderr.prefix(500))")
            throw RuntimeError.commandFailed("run \(name): \(stderr)")
        }

        // Fetch fresh state after start
        print("[ContainerRuntime] \(name): inspecting container state...")
        let info = try await inspect(name: name)
        print("[ContainerRuntime] \(name): state=\(info.state.rawValue) ip=\(info.ipAddress ?? "none")")
        return info
    }

    func stop(name: String) async throws {
        let (_, stderr, code) = try await runCommand(["stop", name])
        guard code == 0 else {
            throw RuntimeError.commandFailed("stop \(name): \(stderr)")
        }
    }

    func remove(name: String) async throws {
        let (_, stderr, code) = try await runCommand(["rm", name])
        guard code == 0 else {
            throw RuntimeError.commandFailed("rm \(name): \(stderr)")
        }
    }

    func list() async throws -> [ContainerInfo] {
        let (stdout, _, _) = try await runCommand(["ls", "--format", "json"])
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let data = Data(trimmed.utf8)
        let entries = try JSONDecoder().decode([ContainerListEntry].self, from: data)
        return entries.map { mapEntry($0) }
    }

    func inspect(name: String) async throws -> ContainerInfo {
        let (stdout, stderr, code) = try await runCommand(["inspect", name])
        guard code == 0 else {
            throw RuntimeError.commandFailed("inspect \(name): \(stderr)")
        }
        let data = Data(stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8)

        // Apple Container inspect returns an array of objects
        if let entries = try? JSONDecoder().decode([ContainerInspectEntry].self, from: data),
           let entry = entries.first
        {
            return mapInspectEntry(entry, name: name)
        }
        // Fallback: single object
        if let entry = try? JSONDecoder().decode(ContainerInspectEntry.self, from: data) {
            return mapInspectEntry(entry, name: name)
        }
        print("[ContainerRuntime] inspect parse failed for \(name), raw: \(stdout.prefix(300))")
        throw RuntimeError.parseError("inspect output for \(name)")
    }

    private func mapInspectEntry(_ e: ContainerInspectEntry, name: String) -> ContainerInfo {
        ContainerInfo(
            name: e.effectiveName ?? name,
            image: e.effectiveImage ?? "",
            state: mapState(e.status ?? ""),
            ipAddress: e.effectiveIP,
            ports: [],
            startedAt: e.startedDate.map { Date(timeIntervalSinceReferenceDate: $0) },
            error: nil
        )
    }

    // MARK: - Shell helper

    func runCommand(_ args: [String]) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let fullCmd = "container " + args.joined(separator: " ")
        print("[ContainerRuntime] exec: \(fullCmd.prefix(200))")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["container"] + args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            print("[ContainerRuntime] exec failed (exit \(proc.terminationStatus)): \(stderr.prefix(300))")
        }

        return (stdout, stderr, proc.terminationStatus)
    }

    // MARK: - Mapping

    private func mapEntry(_ e: ContainerListEntry) -> ContainerInfo {
        ContainerInfo(
            name: e.name ?? "",
            image: e.image ?? "",
            state: mapState(e.status ?? ""),
            ipAddress: e.effectiveIP,
            ports: [],  // TODO: parse port mappings from inspect NetworkSettings
            startedAt: nil,
            error: nil
        )
    }

    private func mapState(_ raw: String) -> ContainerState {
        switch raw.lowercased() {
        case "running":  return .running
        case "stopped", "exited": return .stopped
        case "booting", "starting", "created": return .booting
        default: return .error
        }
    }
}

// MARK: - Errors

enum RuntimeError: Error, CustomStringConvertible {
    case commandFailed(String)
    case parseError(String)

    var description: String {
        switch self {
        case .commandFailed(let msg): "ContainerRuntime command failed: \(msg)"
        case .parseError(let msg):   "ContainerRuntime parse error: \(msg)"
        }
    }
}
