import Foundation
#if canImport(Network)
import Network
#endif

enum HealthCheckError: Error {
    case timeout
    case commandFailed(String)
}

struct HealthCheck {

    // MARK: - TCP connect check

    /// Returns true if a TCP connection to host:port succeeds within timeout.
    static func tcpCheck(host: String, port: Int, timeout: Duration = .seconds(2)) async -> Bool {
        /// Mutable flag shared across two concurrent closures (stateUpdateHandler + watchdog).
        /// Wrapped in a class so both closures capture the same reference; @unchecked Sendable
        /// because mutation is serialised by the NWConnection queue + asyncAfter ordering.
        final class Resolved: @unchecked Sendable { var value = false }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            let deadline = DispatchTime.now() + .seconds(2)
            let resolved = Resolved()

            connection.stateUpdateHandler = { state in
                guard !resolved.value else { return }
                switch state {
                case .ready:
                    resolved.value = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    resolved.value = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: .global())

            // Timeout watchdog
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                guard !resolved.value else { return }
                resolved.value = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Command check

    /// Runs a shell command; returns true if exit code is 0.
    static func commandCheck(command: String, timeout: Duration = .seconds(5)) async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]

        do {
            try proc.run()
        } catch {
            return false
        }

        // Poll until done or timeout
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if proc.isRunning {
            proc.terminate()
            return false
        }
        return proc.terminationStatus == 0
    }

    // MARK: - Wait loop with backoff

    /// Poll a TCP endpoint until ready or timeout. Uses exponential backoff capped at 2 s.
    static func waitForReady(
        host: String,
        port: Int,
        timeout: Duration = .seconds(30),
        interval: Duration = .milliseconds(100)
    ) async throws {
        let start = ContinuousClock.now
        var delay: Duration = .milliseconds(100)

        while ContinuousClock.now - start < timeout {
            if await tcpCheck(host: host, port: port, timeout: .seconds(1)) { return }
            try await Task.sleep(for: delay)
            // Exponential backoff: 100ms -> 200 -> 400 -> 800 -> 1600 -> cap 2000ms
            let nextMs = min(delay.components.attoseconds / 1_000_000_000_000 * 2, 2_000)
            delay = .milliseconds(nextMs)
        }
        throw HealthCheckError.timeout
    }
}

// MARK: - Duration components helper

private extension Duration {
    var milliseconds: Int64 {
        components.attoseconds / 1_000_000_000_000_000
    }
}
