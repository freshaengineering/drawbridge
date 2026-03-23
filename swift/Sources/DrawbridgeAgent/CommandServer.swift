import Foundation

/// Simple stdin/stdout JSON command interface.
/// Allows the Elixir side to drive containers via Port (stdin/stdout) using
/// newline-delimited JSON. Each request may contain an `"id"` field; if present,
/// it is echoed in the response so the caller can correlate concurrent requests.
///
/// Request format:
///   {"id": "1", "cmd": "start",  "name": "...", "image": "...", "ports": [{"host":N,"container":M}], "env": {...}}
///   {"id": "2", "cmd": "stop",   "name": "..."}
///   {"id": "3", "cmd": "status", "name": "..."}
///   {"id": "4", "cmd": "list"}
///   {"id": "5", "cmd": "pull",   "image": "..."}
///   {"id": "6", "cmd": "health"}
///   {"id": "7", "cmd": "image_inspect", "image": "..."}
///
/// Response format:
///   {"id": "1", "ok": true,  "data": <result>}
///   {"id": "2", "ok": false, "error": "<message>", "code": "invalid_args"}
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
            return errorResponse(id: nil, msg: "invalid JSON or missing 'cmd' field", code: "parse_error")
        }

        let id = cmd.id

        do {
            switch cmd.cmd {
            case "start":
                guard let name = cmd.name, let image = cmd.image else {
                    return errorResponse(id: id, msg: "start requires 'name' and 'image'", code: "invalid_args")
                }
                let info = try await manager.startContainer(
                    name: name,
                    image: image,
                    ports: cmd.ports ?? [],
                    env: cmd.env ?? [:]
                )
                return try okResponse(id: id, data: info)

            case "stop":
                guard let name = cmd.name else {
                    return errorResponse(id: id, msg: "stop requires 'name'", code: "invalid_args")
                }
                let ok = try await manager.stopContainer(name: name)
                return try okResponse(id: id, data: ok)

            case "status":
                guard let name = cmd.name else {
                    return errorResponse(id: id, msg: "status requires 'name'", code: "invalid_args")
                }
                let state = await manager.containerStatus(name: name)
                return try okResponse(id: id, data: state.rawValue)

            case "list":
                let infos = await manager.listContainers()
                return try okResponse(id: id, data: infos)

            case "pull":
                guard let image = cmd.image else {
                    return errorResponse(id: id, msg: "pull requires 'image'", code: "invalid_args")
                }
                let ok = try await manager.pullImage(image: image)
                return try okResponse(id: id, data: ok)

            case "health":
                return try okResponse(id: id, data: "pong")

            case "image_inspect":
                guard let image = cmd.image else {
                    return errorResponse(id: id, msg: "image_inspect requires 'image'", code: "invalid_args")
                }
                let result = try await inspectImage(image: image)
                return try okResponse(id: id, data: result)

            default:
                return errorResponse(id: id, msg: "unknown cmd '\(cmd.cmd)'", code: "unknown_command")
            }
        } catch {
            return errorResponse(id: id, msg: error.localizedDescription, code: "runtime_error")
        }
    }

    // MARK: - Image inspect

    private func inspectImage(image: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["container", "image", "inspect", image, "--format", "json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "{}"
    }

    // MARK: - Response helpers

    private func okResponse<T: Encodable>(id: String?, data value: T) throws -> String {
        let wrapper = ResponseEnvelope(id: id, ok: true, data: AnyCodable(value), error: nil, code: nil)
        let data = try encoder.encode(wrapper)
        return String(data: data, encoding: .utf8) ?? errorResponse(id: id, msg: "encoding failed", code: "encode_error")
    }

    private func errorResponse(id: String?, msg: String, code: String) -> String {
        let escaped = msg.replacingOccurrences(of: "\"", with: "\\\"")
        if let id = id {
            return "{\"code\":\"\(code)\",\"error\":\"\(escaped)\",\"id\":\"\(id)\",\"ok\":false}"
        }
        return "{\"code\":\"\(code)\",\"error\":\"\(escaped)\",\"ok\":false}"
    }
}

// MARK: - Wire types

private struct Command: Decodable {
    let id: String?
    let cmd: String
    let name: String?
    let image: String?
    let ports: [[String: Int]]?
    let env: [String: String]?
}

private struct ResponseEnvelope: Encodable {
    let id: String?
    let ok: Bool
    let data: AnyCodable?
    let error: String?
    let code: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let id = id { try container.encode(id, forKey: .id) }
        try container.encode(ok, forKey: .ok)
        if let data = data { try data.encode(to: container.superEncoder(forKey: .data)) }
        if let error = error { try container.encode(error, forKey: .error) }
        if let code = code { try container.encode(code, forKey: .code) }
    }

    enum CodingKeys: String, CodingKey {
        case id, ok, data, error, code
    }
}

/// Type-erased Encodable wrapper so we can put any Encodable into ResponseEnvelope.
private struct AnyCodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) {
        _encode = { encoder in try value.encode(to: encoder) }
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
