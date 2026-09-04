import AppIntents
import SwiftUI
import WidgetKit

struct MyMacsEntry: TimelineEntry {
    enum State: Sendable {
        case ready
        case noSavedMacs
        case unavailable
    }

    let date: Date
    let machines: [WidgetMachineSnapshot]
    let state: State

    static let placeholder = MyMacsEntry(
        date: .now,
        machines: [
            WidgetMachineSnapshot(
                id: UUID(uuidString: "F9577A6A-FED2-4093-B6E5-10A2852C9BBE")!,
                displayName: "Studio Mac",
                connectionKind: .glassyStream,
                lastConnectedAt: .now.addingTimeInterval(-1_800),
                reachability: .reachable,
                reachabilityCheckedAt: .now.addingTimeInterval(-90)
            ),
            WidgetMachineSnapshot(
                id: UUID(uuidString: "EC741557-203F-4641-9A56-A749C2016212")!,
                displayName: "MacBook Pro",
                connectionKind: .vnc,
                lastConnectedAt: .now.addingTimeInterval(-86_400),
                reachability: .unreachable,
                reachabilityCheckedAt: .now.addingTimeInterval(-90)
            ),
            WidgetMachineSnapshot(
                id: UUID(uuidString: "5AE00DD9-D682-4C9D-8DF9-475B30DC9C89")!,
                displayName: "Office Mac mini",
                connectionKind: .vnc,
                lastConnectedAt: nil,
                reachability: .unknown,
                reachabilityCheckedAt: nil
            )
        ],
        state: .ready
    )
}

nonisolated struct MyMacsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MyMacsEntry {
        .placeholder
    }

    func snapshot(
        for configuration: MyMacsConfigurationIntent,
        in context: Context
    ) async -> MyMacsEntry {
        context.isPreview ? .placeholder : entry(for: configuration, family: context.family, date: .now)
    }

    func timeline(
        for configuration: MyMacsConfigurationIntent,
        in context: Context
    ) async -> Timeline<MyMacsEntry> {
        let date = Date.now
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: date)
            ?? date.addingTimeInterval(900)
        let entry = entry(for: configuration, family: context.family, date: date)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func entry(
        for configuration: MyMacsConfigurationIntent,
        family: WidgetFamily,
        date: Date
    ) -> MyMacsEntry {
        let allMachines = WidgetSnapshotStore.appGroup().read()?.machines ?? []
        guard !allMachines.isEmpty else {
            return MyMacsEntry(date: date, machines: [], state: .noSavedMacs)
        }

        let configuredIDs = configuration.machines?.map(\.id)
        let machines = WidgetMachineSelectionResolver().multipleSelection(
            configuredIDs: configuredIDs,
            machines: allMachines,
            limit: family == .systemLarge ? 6 : 3
        )

        return MyMacsEntry(
            date: date,
            machines: machines,
            state: machines.isEmpty ? .unavailable : .ready
        )
    }
}

struct MyMacsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: GlassyDeskWidgetKind.myMacs,
            intent: MyMacsConfigurationIntent.self,
            provider: MyMacsProvider()
        ) { entry in
            MyMacsWidgetView(entry: entry)
        }
        .configurationDisplayName("My Macs")
        .description("See status and connect to several saved Macs.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .promptsForUserConfiguration()
    }
}

private struct MyMacsWidgetView: View {
    let entry: MyMacsEntry

    var body: some View {
        Group {
            if entry.machines.isEmpty {
                emptyView
                    .widgetURL(GlassyDeskWidgetDeepLink.hosts.url)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    header

                    ForEach(entry.machines) { machine in
                        Link(destination: GlassyDeskWidgetDeepLink.connect(machine.id).url) {
                            machineRow(machine)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var header: some View {
        HStack {
            Label("My Macs", systemImage: "rectangle.3.group.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Text("\(entry.machines.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .widgetAccentable()
    }

    private func machineRow(_ machine: WidgetMachineSnapshot) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor(machine.reachability))
                .frame(width: 8, height: 8)

            Image(systemName: machine.connectionKind == .glassyStream
                  ? "bolt.horizontal.fill"
                  : "display")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(machine.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .privacySensitive()

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

            Spacer(minLength: 4)

            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(.tint)
                .widgetAccentable()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Glassy Desk and connects to this Mac")
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: entry.state == .unavailable
                  ? "questionmark.circle"
                  : "rectangle.3.group")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(entry.state == .unavailable ? "Macs unavailable" : "No saved Macs")
                .font(.headline)

            Text(entry.state == .unavailable
                 ? "Edit the widget to update your selection."
                 : "Open Glassy Desk to add a Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview(as: .systemMedium) {
    MyMacsWidget()
} timeline: {
    MyMacsEntry.placeholder
}

#Preview(as: .systemLarge) {
    MyMacsWidget()
} timeline: {
    MyMacsEntry.placeholder
}
