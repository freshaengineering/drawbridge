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

// MARK: - Wire types for Apple Container CLI JSON output

/// `container inspect` output format
struct ContainerInspectEntry: Decodable, Sendable {
    let status: String?
    let startedDate: Double?
    let networks: [InspectNetwork]?
    let configuration: InspectConfig?

    struct InspectNetwork: Decodable, Sendable {
        let network: String?
        let ipv4Address: String?
        let ipAddress: String?

        /// ipv4Address comes as "192.168.64.8/24" — strip the CIDR suffix
        var effectiveIP: String? {
            if let addr = ipv4Address ?? ipAddress {
                return addr.split(separator: "/").first.map(String.init)
            }
            return nil
        }
    }

    struct InspectConfig: Decodable, Sendable {
        let id: String?
        let image: InspectImage?

        struct InspectImage: Decodable, Sendable {
            let reference: String?
        }
    }

    var effectiveIP: String? {
        networks?.first(where: { $0.effectiveIP != nil })?.effectiveIP
    }

    var effectiveName: String? { configuration?.id }
    var effectiveImage: String? { configuration?.image?.reference }
}

/// `container ls --format json` output format
struct ContainerListEntry: Decodable, Sendable {
    let id: String?
    let name: String?
    let image: String?
    let status: String?
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
