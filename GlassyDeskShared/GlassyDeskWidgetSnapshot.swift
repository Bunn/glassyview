import Foundation

enum GlassyDeskWidgetKind {
    static let quickConnect = "GlassyDeskQuickConnect"
    static let myMacs = "GlassyDeskMyMacs"
}

enum GlassyDeskAppGroup {
    static let identifier = "group.dev.bunn.glassydesk"
}

enum WidgetConnectionKind: String, Codable, Hashable, Sendable {
    case vnc
    case glassyStream
}

enum WidgetMachineReachability: String, Codable, Hashable, Sendable {
    case unknown
    case checking
    case reachable
    case unreachable
}

/// App-only input to the snapshot builder. Keep connection details out of this type.
struct WidgetMachineData: Hashable, Sendable {
    let id: UUID
    let rawName: String
    let connectionKind: WidgetConnectionKind
    let lastConnectedAt: Date?
    let sortOrder: Int
    let reachability: WidgetMachineReachability?
}

/// The complete, deliberately limited representation a widget may read.
struct WidgetMachineSnapshot: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let connectionKind: WidgetConnectionKind
    let lastConnectedAt: Date?
    let reachability: WidgetMachineReachability
    let reachabilityCheckedAt: Date?
}

struct GlassyDeskWidgetSnapshot: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let machines: [WidgetMachineSnapshot]

    init(generatedAt: Date, machines: [WidgetMachineSnapshot]) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.machines = machines
    }
}

struct GlassyDeskWidgetSnapshotBuilder: Sendable {
    static let maximumMachineCount = 50
    static let maximumNameLength = 80
    static let fallbackName = "Saved Computer"

    func build(
        machines: [WidgetMachineData],
        previous: GlassyDeskWidgetSnapshot? = nil,
        generatedAt: Date = .now,
        reachabilityCheckedAt: Date? = nil
    ) -> GlassyDeskWidgetSnapshot {
        let previousByID = (previous?.machines ?? []).reduce(into: [:]) { result, machine in
            result[machine.id] = machine
        }
        var seenIDs = Set<UUID>()

        let snapshots = machines
            .sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.id.uuidString < $1.id.uuidString
            }
            .filter { seenIDs.insert($0.id).inserted }
            .prefix(Self.maximumMachineCount)
            .map { machine in
                let previousMachine = previousByID[machine.id]
                let currentReachability = machine.reachability

                return WidgetMachineSnapshot(
                    id: machine.id,
                    displayName: sanitizedName(machine.rawName),
                    connectionKind: machine.connectionKind,
                    lastConnectedAt: machine.lastConnectedAt,
                    reachability: currentReachability ?? previousMachine?.reachability ?? .unknown,
                    reachabilityCheckedAt: currentReachability == nil
                        ? previousMachine?.reachabilityCheckedAt
                        : reachabilityCheckedAt
                )
            }

        return GlassyDeskWidgetSnapshot(generatedAt: generatedAt, machines: Array(snapshots))
    }

    private func sanitizedName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.fallbackName }
        return String(trimmed.prefix(Self.maximumNameLength))
    }
}

struct WidgetMachineSelectionResolver: Sendable {
    func quickSelection(
        configuredID: UUID?,
        machines: [WidgetMachineSnapshot]
    ) -> WidgetMachineSnapshot? {
        guard let configuredID else { return machines.first }
        return machines.first { $0.id == configuredID }
    }

    func multipleSelection(
        configuredIDs: [UUID]?,
        machines: [WidgetMachineSnapshot],
        limit: Int
    ) -> [WidgetMachineSnapshot] {
        guard limit > 0 else { return [] }
        guard let configuredIDs, !configuredIDs.isEmpty else {
            return Array(machines.prefix(limit))
        }

        let machinesByID = machines.reduce(into: [UUID: WidgetMachineSnapshot]()) { result, machine in
            if result[machine.id] == nil { result[machine.id] = machine }
        }
        var seenIDs = Set<UUID>()
        var selected: [WidgetMachineSnapshot] = []

        for id in configuredIDs where seenIDs.insert(id).inserted {
            guard let machine = machinesByID[id] else { continue }
            selected.append(machine)
            if selected.count == limit { break }
        }

        return selected
    }
}
