import Foundation

/// A saved connection. Metadata lives in app storage; the password is stored
/// separately, keyed by the machine's id.
struct SavedMachine: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var connectionMode: RemoteConnectionMode
    var glassyHostIdentifier: String?
    var glassyHostName: String?
    var glassyHostAddresses: [String]
    var macAddress: String?
    var lastConnectedAt: Date?

    init(id: UUID = UUID(),
         name: String,
         host: String,
         port: UInt16 = 5900,
         username: String,
         connectionMode: RemoteConnectionMode = .default,
         glassyHostIdentifier: String? = nil,
         glassyHostName: String? = nil,
         glassyHostAddresses: [String] = [],
         macAddress: String? = nil,
         lastConnectedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.connectionMode = connectionMode
        self.glassyHostIdentifier = glassyHostIdentifier
        self.glassyHostName = glassyHostName
        self.glassyHostAddresses = Array(glassyHostAddresses.prefix(8))
        self.macAddress = macAddress
        self.lastConnectedAt = lastConnectedAt
    }

    var displayName: String {
        name.isEmpty ? host : name
    }

    var subtitle: String {
        let hostPort = "\(host):\(String(port))"
        let endpoint = username.isEmpty ? hostPort : "\(username)@\(hostPort)"

        guard connectionMode != .vnc else { return endpoint }
        let streamHost = glassyHostName.flatMap { $0.isEmpty ? nil : $0 }
        let fallbackHost = host.isEmpty ? nil : host
        return [connectionMode.title, streamHost ?? fallbackHost]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var wakeOnLANAddress: MACAddress? {
        guard let macAddress else { return nil }
        return MACAddress(macAddress)
    }
}

extension SavedMachine {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case username
        case connectionMode
        case glassyHostIdentifier
        case glassyHostName
        case glassyHostAddresses
        case macAddress
        case lastConnectedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        connectionMode = try container.decodeIfPresent(RemoteConnectionMode.self,
                                                       forKey: .connectionMode) ?? .default
        glassyHostIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .glassyHostIdentifier
        )
        glassyHostName = try container.decodeIfPresent(
            String.self,
            forKey: .glassyHostName
        )
        glassyHostAddresses = Array((try container.decodeIfPresent(
            [String].self,
            forKey: .glassyHostAddresses
        ) ?? []).prefix(8))
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }
}
