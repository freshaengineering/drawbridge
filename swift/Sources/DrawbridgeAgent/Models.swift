import Foundation

/// Lifecycle state of a managed container
enum ContainerState: String, Codable, Sendable {
    case notPulled = "not_pulled"
    case stopped
    case booting
    case running
    case error
}

/// Information about a managed container
struct ContainerInfo: Codable, Sendable {
    let name: String
    let image: String
    var state: ContainerState
    var ipAddress: String?
    var ports: [PortMapping]
    var startedAt: Date?
    var error: String?
}

struct PortMapping: Codable, Sendable {
    let hostPort: Int
    let containerPort: Int
    let proto: String  // "tcp" or "udp"

    init(hostPort: Int, containerPort: Int, proto: String = "tcp") {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }
}

/// Result type for container operations
enum ContainerResult: Sendable {
    case ok(ContainerInfo)
    case error(String)
}

// MARK: - Wire types for `container ls --format json` / inspect output

struct ContainerListEntry: Decodable, Sendable {
    let id: String?
    let name: String?
    let image: String?
    let status: String?
    // Apple Container may use "IP" or "ipAddress"; try both
    let ip: String?
    let ipAddress: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case image = "Image"
        case status = "Status"
        case ip = "IP"
        case ipAddress = "IPAddress"
    }

    var effectiveIP: String? { ip ?? ipAddress }
}
