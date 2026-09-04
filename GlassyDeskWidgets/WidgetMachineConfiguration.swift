import AppIntents
import Foundation

struct WidgetMachineEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Saved Mac")
    static let defaultQuery = WidgetMachineQuery()

    let id: UUID
    let displayName: String
    let connectionKind: WidgetConnectionKind

    init(machine: WidgetMachineSnapshot) {
        id = machine.id
        displayName = machine.displayName
        connectionKind = machine.connectionKind
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: displayName),
            subtitle: connectionKind == .glassyStream ? "Glassy Stream" : "Screen Sharing"
        )
    }
}

struct WidgetMachineQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [WidgetMachineEntity.ID]) async throws -> [WidgetMachineEntity] {
        let entities = allEntities
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        var seenIDs = Set<UUID>()
        return identifiers
            .filter { seenIDs.insert($0).inserted }
            .compactMap { byID[$0] }
    }

    func entities(matching string: String) async throws -> [WidgetMachineEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allEntities }
        return allEntities.filter { $0.displayName.localizedStandardContains(query) }
    }

    func suggestedEntities() async throws -> [WidgetMachineEntity] {
        allEntities
    }

    func defaultResult() async -> WidgetMachineEntity? {
        allEntities.first
    }

    private var allEntities: [WidgetMachineEntity] {
        (WidgetSnapshotStore.appGroup().read()?.machines ?? []).map(WidgetMachineEntity.init)
    }
}

struct QuickConnectConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Quick Connect"
    static let description = IntentDescription("Choose the Mac this widget connects to.")

    @Parameter(title: "Mac")
    var machine: WidgetMachineEntity?
}

struct MyMacsConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "My Macs"
    static let description = IntentDescription("Choose and arrange the Macs shown in the widget.")

    @Parameter(
        title: "Macs",
        size: [
            .systemMedium: .init(min: 1, max: 3),
            .systemLarge: .init(min: 1, max: 6)
        ]
    )
    var machines: [WidgetMachineEntity]?
}
