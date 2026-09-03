import Foundation
import SwiftData

@Model
final class SavedMachineRecord {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 5900
    var username: String = ""
    var connectionModeRawValue: String = RemoteConnectionMode.default.rawValue
    var glassyHostIdentifier: String?
    var glassyHostName: String?
    /// Optional additive storage lets older SwiftData/CloudKit records migrate
    /// without a required value or a transformable collection migration.
    var glassyHostAddressesData: Data?
    var macAddress: String?
    @Attribute(.allowsCloudEncryption) var password: String?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var lastConnectedAt: Date?
    var sessionPreferencesData: Data?
    var sortOrder: Int = 0

    init(id: UUID = UUID(),
         name: String = "",
         host: String = "",
         port: Int = 5900,
         username: String = "",
         connectionModeRawValue: String = RemoteConnectionMode.default.rawValue,
         glassyHostIdentifier: String? = nil,
         glassyHostName: String? = nil,
         glassyHostAddressesData: Data? = nil,
         macAddress: String? = nil,
         password: String? = nil,
         createdAt: Date = .now,
         updatedAt: Date = .now,
         lastConnectedAt: Date? = nil,
         sessionPreferencesData: Data? = nil,
         sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.connectionModeRawValue = connectionModeRawValue
        self.glassyHostIdentifier = glassyHostIdentifier
        self.glassyHostName = glassyHostName
        self.glassyHostAddressesData = glassyHostAddressesData
        self.macAddress = macAddress
        self.password = password
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConnectedAt = lastConnectedAt
        self.sessionPreferencesData = sessionPreferencesData
        self.sortOrder = sortOrder
    }

    convenience init(machine: SavedMachine, password: String? = nil, sortOrder: Int) {
        self.init(id: machine.id,
                  name: machine.name,
                  host: machine.host,
                  port: Int(machine.port),
                  username: machine.username,
                  connectionModeRawValue: machine.connectionMode.rawValue,
                  glassyHostIdentifier: machine.glassyHostIdentifier,
                  glassyHostName: machine.glassyHostName,
                  glassyHostAddressesData: Self.encodeAddresses(machine.glassyHostAddresses),
                  macAddress: machine.macAddress,
                  password: password,
                  lastConnectedAt: machine.lastConnectedAt,
                  sortOrder: sortOrder)
    }

    var savedMachine: SavedMachine {
        SavedMachine(id: id,
                     name: name,
                     host: host,
                     port: UInt16(clamping: port),
                     username: username,
                     connectionMode: RemoteConnectionMode(rawValue: connectionModeRawValue) ?? .default,
                     glassyHostIdentifier: glassyHostIdentifier,
                     glassyHostName: glassyHostName,
                     glassyHostAddresses: glassyHostAddressesData.flatMap {
                         try? JSONDecoder().decode([String].self, from: $0)
                     } ?? [],
                     macAddress: macAddress,
                     lastConnectedAt: lastConnectedAt)
    }

    func update(from machine: SavedMachine, sortOrder: Int? = nil) {
        name = machine.name
        host = machine.host
        port = Int(machine.port)
        username = machine.username
        connectionModeRawValue = machine.connectionMode.rawValue
        glassyHostIdentifier = machine.glassyHostIdentifier
        glassyHostName = machine.glassyHostName
        glassyHostAddressesData = Self.encodeAddresses(machine.glassyHostAddresses)
        macAddress = machine.macAddress
        lastConnectedAt = machine.lastConnectedAt ?? lastConnectedAt
        updatedAt = .now

        if let sortOrder {
            self.sortOrder = sortOrder
        }
    }

    private static func encodeAddresses(_ addresses: [String]) -> Data? {
        guard !addresses.isEmpty else { return nil }
        return try? JSONEncoder().encode(Array(addresses.prefix(8)))
    }
}
