import Foundation
import WidgetKit

@MainActor
protocol WidgetSnapshotPublishing {
    func publish(machines: [SavedMachine])
    func publish(
        machines: [SavedMachine],
        reachabilityStatuses: [UUID: MachineReachabilityStatus],
        checkedAt: Date
    )
}

@MainActor
struct NoopWidgetSnapshotPublisher: WidgetSnapshotPublishing {
    func publish(machines: [SavedMachine]) {}

    func publish(
        machines: [SavedMachine],
        reachabilityStatuses: [UUID: MachineReachabilityStatus],
        checkedAt: Date
    ) {}
}

@MainActor
protocol WidgetTimelineReloading {
    func reloadWidgetTimelines()
}

@MainActor
struct WidgetCenterTimelineReloader: WidgetTimelineReloading {
    func reloadWidgetTimelines() {
        WidgetCenter.shared.reloadTimelines(ofKind: GlassyDeskWidgetKind.quickConnect)
        WidgetCenter.shared.reloadTimelines(ofKind: GlassyDeskWidgetKind.myMacs)
    }
}

@MainActor
struct WidgetSnapshotPublisher: WidgetSnapshotPublishing {
    private let store: WidgetSnapshotStore
    private let builder: GlassyDeskWidgetSnapshotBuilder
    private let timelineReloader: any WidgetTimelineReloading

    init(
        store: WidgetSnapshotStore = .appGroup(),
        builder: GlassyDeskWidgetSnapshotBuilder = .init(),
        timelineReloader: any WidgetTimelineReloading = WidgetCenterTimelineReloader()
    ) {
        self.store = store
        self.builder = builder
        self.timelineReloader = timelineReloader
    }

    func publish(machines: [SavedMachine]) {
        publish(machines: machines, reachabilityStatuses: nil, checkedAt: nil)
    }

    func publish(
        machines: [SavedMachine],
        reachabilityStatuses: [UUID: MachineReachabilityStatus],
        checkedAt: Date
    ) {
        publish(
            machines: machines,
            reachabilityStatuses: reachabilityStatuses,
            checkedAt: Optional(checkedAt)
        )
    }

    private func publish(
        machines: [SavedMachine],
        reachabilityStatuses: [UUID: MachineReachabilityStatus]?,
        checkedAt: Date?
    ) {
        let previous = store.read()
        let data = machines.enumerated().map { offset, machine in
            Self.machineData(
                from: machine,
                sortOrder: offset,
                reachability: reachabilityStatuses?[machine.id]
            )
        }
        let snapshot = builder.build(
            machines: data,
            previous: previous,
            generatedAt: .now,
            reachabilityCheckedAt: checkedAt
        )

        do {
            try store.write(snapshot)
            if Self.reloadFingerprint(for: previous) != Self.reloadFingerprint(for: snapshot) {
                timelineReloader.reloadWidgetTimelines()
            }
        } catch {
            AppLog.storage.error("Failed to publish widget snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func machineData(
        from machine: SavedMachine,
        sortOrder: Int,
        reachability: MachineReachabilityStatus? = nil
    ) -> WidgetMachineData {
        WidgetMachineData(
            id: machine.id,
            rawName: machine.name,
            connectionKind: machine.connectionMode == .glassyStream ? .glassyStream : .vnc,
            lastConnectedAt: machine.lastConnectedAt,
            sortOrder: sortOrder,
            reachability: reachability.map(Self.widgetReachability)
        )
    }

    private static func widgetReachability(
        _ status: MachineReachabilityStatus
    ) -> WidgetMachineReachability {
        switch status {
        case .checking, .waking:
            .checking
        case .reachable:
            .reachable
        case .unreachable:
            .unreachable
        }
    }

    private struct ReloadFingerprint: Equatable {
        let id: UUID
        let displayName: String
        let connectionKind: WidgetConnectionKind
        let lastConnectedAt: Date?
        let reachability: WidgetMachineReachability
    }

    private static func reloadFingerprint(
        for snapshot: GlassyDeskWidgetSnapshot?
    ) -> [ReloadFingerprint]? {
        snapshot?.machines.map {
            ReloadFingerprint(
                id: $0.id,
                displayName: $0.displayName,
                connectionKind: $0.connectionKind,
                lastConnectedAt: $0.lastConnectedAt,
                reachability: $0.reachability
            )
        }
    }
}
