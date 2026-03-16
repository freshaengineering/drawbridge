import Foundation

/// Simple stdin/stdout JSON command interface.
/// Allows the Elixir side to drive containers via Port (stdin/stdout) as a
/// fallback when Erlang distribution (swift-erlang-actor-system) isn't available.
///
/// Request format:
///   {"cmd": "start",  "name": "...", "image": "...", "ports": [{"host":N,"container":M}], "env": {...}}
///   {"cmd": "stop",   "name": "..."}
///   {"cmd": "status", "name": "..."}
///   {"cmd": "list"}
///   {"cmd": "pull",   "image": "..."}
///
/// Response format:
///   {"ok": true,  "data": <result>}
///   {"ok": false, "error": "<message>"}
actor CommandServer {

    let manager: ContainerManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(manager: ContainerManager) {
        self.manager = manager
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
    }

    func run() async throws {
        print("[CommandServer] Ready. Accepting JSON commands on stdin.")
        // Flush stdout immediately so the Elixir port sees it
        fflush(stdout)

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let response = await handle(line)
            print(response)
            fflush(stdout)
        }
    }

    // MARK: - Dispatch

    private func handle(_ line: String) async -> String {
        guard let data = line.data(using: .utf8),
              let cmd = try? decoder.decode(Command.self, from: data)
        else {
            return errorResponse("invalid JSON or missing 'cmd' field")
        }

        do {
            switch cmd.cmd {
            case "start":
                guard let name = cmd.name, let image = cmd.image else {
                    return errorResponse("start requires 'name' and 'image'")
                }
                let info = try await manager.startContainer(
                    name: name,
                    image: image,
                    ports: cmd.ports ?? [],
                    env: cmd.env ?? [:]
                )
                return try okResponse(info)

            case "stop":
                guard let name = cmd.name else { return errorResponse("stop requires 'name'") }
                let ok = try await manager.stopContainer(name: name)
                return try okResponse(ok)

            case "status":
                guard let name = cmd.name else { return errorResponse("status requires 'name'") }
                let state = await manager.containerStatus(name: name)
                return try okResponse(state.rawValue)

            case "list":
                let infos = await manager.listContainers()
                return try okResponse(infos)

            case "pull":
                guard let image = cmd.image else { return errorResponse("pull requires 'image'") }
                let ok = try await manager.pullImage(image: image)
                return try okResponse(ok)

            default:
                return errorResponse("unknown cmd '\(cmd.cmd)'")
            }
        } catch {
            return errorResponse(error.localizedDescription)
        }
    }

    // MARK: - Response helpers

    private func okResponse<T: Encodable>(_ value: T) throws -> String {
        let wrapper = OkResponse(ok: true, data: value)
        let data = try encoder.encode(wrapper)
        return String(data: data, encoding: .utf8) ?? "{\"ok\":false,\"error\":\"encoding failed\"}"
    }

    private func errorResponse(_ msg: String) -> String {
        "{\"ok\":false,\"error\":\"\(msg.replacingOccurrences(of: "\"", with: "\\\""))\"}"
    }
}

// MARK: - Wire types

private struct Command: Decodable {
    let cmd: String
    let name: String?
    let image: String?
    let ports: [[String: Int]]?
    let env: [String: String]?
}

private struct OkResponse<T: Encodable>: Encodable {
    let ok: Bool
    let data: T
}
