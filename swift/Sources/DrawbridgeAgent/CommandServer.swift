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

    // TODO: NSLock inside a Swift actor is a code smell — actors already serialize
    // access to mutable state. The lock exists because pullImageStreaming's onLine
    // callback fires from Task.detached on an arbitrary thread, and we need to
    // prevent interleaved stdout writes. Refactor to route progress writes through
    // the actor's serial executor instead.
    private let outputLock = NSLock()

    nonisolated private func writeLine(_ line: String) {
        outputLock.lock()
        print(line)
        fflush(stdout)
        outputLock.unlock()
    }

    func run() async throws {
        writeLine("[CommandServer] Ready. Accepting JSON commands on stdin.")

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            await handle(line)
        }
    }

    // MARK: - Dispatch

    private func handle(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let cmd = try? decoder.decode(Command.self, from: data)
        else {
            writeLine(errorResponse(id: nil, msg: "invalid JSON or missing 'cmd' field", code: "parse_error"))
            return
        }

        let id = cmd.id

        do {
            switch cmd.cmd {
            case "start":
                guard let name = cmd.name, let image = cmd.image else {
                    writeLine(errorResponse(id: id, msg: "start requires 'name' and 'image'", code: "invalid_args"))
                    return
                }
                let info = try await manager.startContainer(
                    name: name,
                    image: image,
                    ports: cmd.ports ?? [],
                    env: cmd.env ?? [:]
                )
                writeLine(try okResponse(id: id, data: info))

            case "stop":
                guard let name = cmd.name else {
                    writeLine(errorResponse(id: id, msg: "stop requires 'name'", code: "invalid_args"))
                    return
                }
                let ok = try await manager.stopContainer(name: name)
                writeLine(try okResponse(id: id, data: ok))

            case "status":
                guard let name = cmd.name else {
                    writeLine(errorResponse(id: id, msg: "status requires 'name'", code: "invalid_args"))
                    return
                }
                let state = await manager.containerStatus(name: name)
                writeLine(try okResponse(id: id, data: state.rawValue))

            case "list":
                let infos = await manager.listContainers()
                writeLine(try okResponse(id: id, data: infos))

            case "pull":
                guard let image = cmd.image else {
                    writeLine(errorResponse(id: id, msg: "pull requires 'image'", code: "invalid_args"))
                    return
                }
                _ = try await manager.pullImageStreaming(image: image) { [weak self] progressLine in
                    guard let self = self else { return }
                    let progress = self.parsePullProgress(line: progressLine, image: image)
                    let progressJson = self.progressResponse(id: id, data: progress)
                    self.writeLine(progressJson)
                }
                writeLine(try okResponse(id: id, data: ["image": image]))

            case "health":
                writeLine(try okResponse(id: id, data: "pong"))

            case "image_inspect":
                guard let image = cmd.image else {
                    writeLine(errorResponse(id: id, msg: "image_inspect requires 'image'", code: "invalid_args"))
                    return
                }
                let result = try await inspectImage(image: image)
                writeLine(try okResponse(id: id, data: result))

            default:
                writeLine(errorResponse(id: id, msg: "unknown cmd '\(cmd.cmd)'", code: "unknown_command"))
            }
        } catch {
            writeLine(errorResponse(id: id, msg: String(describing: error), code: "runtime_error"))
        }
    }

    // MARK: - Pull progress parsing

    /// Parse a pull progress line from the container CLI.
    /// Attempts to extract percent/downloaded/total from typical progress output.
    private nonisolated func parsePullProgress(line: String, image: String) -> [String: String] {
        var result: [String: String] = ["image": image, "layer": line]

        // Try to match patterns like "45%" or "(45%)" or "45.2%"
        if let percentMatch = line.range(of: #"(\d+(?:\.\d+)?)\s*%"#, options: .regularExpression) {
            let raw = line[percentMatch].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            result["percent"] = raw
        }

        // Try to match byte patterns like "230MB/512MB" or "230 MB / 512 MB"
        let bytePattern = #"(\d+(?:\.\d+)?\s*[KMGTkmgt][Bb]?)\s*/\s*(\d+(?:\.\d+)?\s*[KMGTkmgt][Bb]?)"#
        if let byteMatch = line.range(of: bytePattern, options: .regularExpression) {
            let matched = String(line[byteMatch])
            let parts = matched.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                result["downloaded"] = parts[0]
                result["total"] = parts[1]
            }
        }

        return result
    }

    /// Build a progress JSON line (not a final response — "progress": true).
    private nonisolated func progressResponse(id: String?, data: [String: String]) -> String {
        var parts: [String] = []
        if let id = id { parts.append("\"id\":\"\(id)\"") }
        parts.append("\"progress\":true")
        let dataEntries = data.sorted(by: { $0.key < $1.key }).map { k, v in
            "\"\(k)\":\"\(v.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        parts.append("\"data\":{\(dataEntries.joined(separator: ","))}")
        return "{\(parts.joined(separator: ","))}"
    }

    // MARK: - Image inspect

    // TODO: waitUntilExit() blocks this actor method synchronously, preventing
    // all other command processing while the inspect runs. Should be refactored
    // to use async process handling (e.g. terminationHandler or structured concurrency).
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
