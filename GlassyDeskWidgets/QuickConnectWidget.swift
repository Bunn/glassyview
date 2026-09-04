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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.widgetRenderingMode) private var renderingMode

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
        ZStack(alignment: .topLeading) {
            if !dynamicTypeSize.isAccessibilitySize {
                screenDecoration
            }

            VStack(alignment: .leading, spacing: 0) {
                header

                Spacer(minLength: 8)

                Text(machine.displayName)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : 2)
                    .minimumScaleFactor(0.85)
                    .privacySensitive()

                Spacer(minLength: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        compactStatusTitle(machine.reachability),
                        systemImage: statusSymbol(machine.reachability)
                    )
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(statusForeground(machine.reachability))

                    if !dynamicTypeSize.isAccessibilitySize {
                        recencyText(for: machine)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(machine.displayName)
        .accessibilityValue("\(compactStatusTitle(machine.reachability)). \(accessibilityRecencyTitle(for: machine)).")
        .accessibilityHint("Connects to this Mac")
    }

    private var emptyView: some View {
        ZStack(alignment: .topLeading) {
            if !dynamicTypeSize.isAccessibilitySize {
                screenDecoration
            }

            VStack(alignment: .leading, spacing: 0) {
                header

                Spacer(minLength: 8)

                Label(emptyStatusTitle, systemImage: emptyStatusSymbol)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.tint)
                    .widgetAccentable()

                Text(emptyTitle)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .padding(.top, 3)

                if !dynamicTypeSize.isAccessibilitySize {
                    Text(emptyMessage)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 3)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(emptyTitle)
        .accessibilityValue(emptyMessage)
        .accessibilityHint("Opens Glassy Desk")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Quick Connect")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Image(systemName: "arrow.up.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tint)
                .widgetAccentable()
        }
    }

    private var screenDecoration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(decorationColor.opacity(decorationOpacity * 0.72), lineWidth: 1.2)
                .frame(width: 65, height: 48)
                .offset(x: 11, y: -8)

            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(decorationColor.opacity(decorationOpacity * 0.34))
                .frame(width: 70, height: 53)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(decorationColor.opacity(decorationOpacity), lineWidth: 1.2)
                }
                .offset(x: -7, y: 7)
        }
        .rotationEffect(.degrees(-7))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .offset(x: 28, y: 2)
        .widgetAccentable()
        .accessibilityHidden(true)
    }

    private var decorationColor: Color {
        renderingMode == .fullColor ? Color.accentColor : Color.primary
    }

    private var decorationOpacity: Double {
        renderingMode == .fullColor ? 0.16 : 0.10
    }

    private func compactStatusTitle(_ status: WidgetMachineReachability) -> String {
        switch status {
        case .unknown:
            String(localized: "Unknown")
        case .checking:
            String(localized: "Checking")
        case .reachable:
            String(localized: "Online")
        case .unreachable:
            String(localized: "Offline")
        }
    }

    private func statusSymbol(_ status: WidgetMachineReachability) -> String {
        switch status {
        case .unknown:
            "questionmark.circle"
        case .checking:
            "ellipsis.circle"
        case .reachable:
            "checkmark.circle.fill"
        case .unreachable:
            "xmark.circle.fill"
        }
    }

    private func statusForeground(_ status: WidgetMachineReachability) -> Color {
        renderingMode == .fullColor ? statusColor(status) : Color.primary
    }

    @ViewBuilder
    private func recencyText(for machine: WidgetMachineSnapshot) -> some View {
        if let checkedAt = machine.reachabilityCheckedAt {
            Text("Checked \(checkedAt, style: .relative)")
        } else if machine.reachability == .checking {
            Text("Checking now")
        } else {
            Text("Not checked yet")
        }
    }

    private func accessibilityRecencyTitle(for machine: WidgetMachineSnapshot) -> String {
        guard let checkedAt = machine.reachabilityCheckedAt else {
            return machine.reachability == .checking
                ? String(localized: "Checking now")
                : String(localized: "Not checked yet")
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: min(checkedAt, entry.date), relativeTo: entry.date)
        return String(localized: "Checked \(relative)")
    }

    private var emptyTitle: String {
        entry.state == .unavailable
            ? String(localized: "Mac unavailable")
            : String(localized: "No saved Macs")
    }

    private var emptyMessage: String {
        entry.state == .unavailable
            ? String(localized: "Touch and hold to choose another Mac.")
            : String(localized: "Open Glassy Desk to add one.")
    }

    private var emptyStatusTitle: String {
        entry.state == .unavailable
            ? String(localized: "Choose another")
            : String(localized: "Setup needed")
    }

    private var emptyStatusSymbol: String {
        entry.state == .unavailable ? "exclamationmark.circle.fill" : "plus.circle.fill"
    }
}

#Preview(as: .systemSmall) {
    QuickConnectWidget()
} timeline: {
    QuickConnectEntry.placeholder
}
