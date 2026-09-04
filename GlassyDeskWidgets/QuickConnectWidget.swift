import AppIntents
import SwiftUI
import WidgetKit

struct QuickConnectEntry: TimelineEntry {
    enum State: Sendable {
        case ready
        case noSavedMacs
        case unavailable
    }

    let date: Date
    let machine: WidgetMachineSnapshot?
    let state: State

    static let placeholder = QuickConnectEntry(
        date: .now,
        machine: WidgetMachineSnapshot(
            id: UUID(uuidString: "A37C54A9-E671-4E73-A854-858B37891354")!,
            displayName: "Studio Mac",
            connectionKind: .glassyStream,
            lastConnectedAt: .now.addingTimeInterval(-3_600),
            reachability: .reachable,
            reachabilityCheckedAt: .now.addingTimeInterval(-90)
        ),
        state: .ready
    )
}

nonisolated struct QuickConnectProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickConnectEntry {
        .placeholder
    }

    func snapshot(
        for configuration: QuickConnectConfigurationIntent,
        in context: Context
    ) async -> QuickConnectEntry {
        context.isPreview ? .placeholder : entry(for: configuration, date: .now)
    }

    func timeline(
        for configuration: QuickConnectConfigurationIntent,
        in context: Context
    ) async -> Timeline<QuickConnectEntry> {
        let date = Date.now
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: date)
            ?? date.addingTimeInterval(900)
        return Timeline(entries: [entry(for: configuration, date: date)], policy: .after(nextUpdate))
    }

    private func entry(
        for configuration: QuickConnectConfigurationIntent,
        date: Date
    ) -> QuickConnectEntry {
        let machines = WidgetSnapshotStore.appGroup().read()?.machines ?? []
        guard !machines.isEmpty else {
            return QuickConnectEntry(date: date, machine: nil, state: .noSavedMacs)
        }

        let configuredID = configuration.machine?.id
        let machine = WidgetMachineSelectionResolver().quickSelection(
            configuredID: configuredID,
            machines: machines
        )

        return QuickConnectEntry(
            date: date,
            machine: machine,
            state: machine == nil ? .unavailable : .ready
        )
    }
}

struct QuickConnectWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: GlassyDeskWidgetKind.quickConnect,
            intent: QuickConnectConfigurationIntent.self,
            provider: QuickConnectProvider()
        ) { entry in
            QuickConnectWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Connect")
        .description("Connect to one saved Mac with a tap.")
        .supportedFamilies([.systemSmall])
        .promptsForUserConfiguration()
    }
}

private struct QuickConnectWidgetView: View {
    let entry: QuickConnectEntry

    var body: some View {
        Group {
            if let machine = entry.machine {
                readyView(machine)
                    .widgetURL(GlassyDeskWidgetDeepLink.connect(machine.id).url)
            } else {
                emptyView
                    .widgetURL(GlassyDeskWidgetDeepLink.hosts.url)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func readyView(_ machine: WidgetMachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Image(systemName: machine.connectionKind == .glassyStream
                      ? "bolt.horizontal.circle.fill"
                      : "display")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .widgetAccentable()

                Spacer(minLength: 4)
                statusDot(machine.reachability)
            }

            Spacer(minLength: 2)

            Text(machine.displayName)
                .font(.headline)
                .lineLimit(2)
                .privacySensitive()

            statusLine(for: machine)

            Label("Connect", systemImage: "arrow.right.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .widgetAccentable()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Glassy Desk and connects to this Mac")
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: entry.state == .unavailable
                  ? "questionmark.circle"
                  : "desktopcomputer")
                .font(.title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(entry.state == .unavailable ? "Mac unavailable" : "No saved Macs")
                .font(.headline)
                .lineLimit(2)

            Text(entry.state == .unavailable
                 ? "Edit the widget to choose another."
                 : "Open Glassy Desk to add one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func statusLine(for machine: WidgetMachineSnapshot) -> some View {
        HStack(spacing: 3) {
            Text(statusTitle(machine.reachability))
            if let checkedAt = machine.reachabilityCheckedAt {
                Text("·")
                Text(checkedAt, style: .relative)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func statusDot(_ status: WidgetMachineReachability) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 9, height: 9)
            .accessibilityLabel(statusTitle(status))
    }
}

#Preview(as: .systemSmall) {
    QuickConnectWidget()
} timeline: {
    QuickConnectEntry.placeholder
}
