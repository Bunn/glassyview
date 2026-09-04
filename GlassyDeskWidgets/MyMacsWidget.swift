import AppIntents
import Foundation
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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            if redactionReasons.contains(.privacy), !entry.machines.isEmpty {
                privacyView
                    .widgetURL(GlassyDeskWidgetDeepLink.hosts.url)
                    .unredacted()
            } else if entry.machines.isEmpty {
                emptyView
                    .widgetURL(GlassyDeskWidgetDeepLink.hosts.url)
            } else {
                readyView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .privacySensitive(!entry.machines.isEmpty)
        .containerBackground(for: .widget) {
            widgetBackground
        }
    }

    @ViewBuilder
    private var readyView: some View {
        switch family {
        case .systemLarge:
            largeView
        default:
            mediumView
        }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            HStack(spacing: 8) {
                ForEach(entry.machines.prefix(3)) { machine in
                    machineLink(machine, style: .medium)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            largeTiles
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var largeTiles: some View {
        let machines = Array(entry.machines.prefix(6))

        switch machines.count {
        case 0:
            EmptyView()
        case 1:
            machineLink(machines[0], style: .hero)
        case 2:
            HStack(spacing: 10) {
                machineLink(machines[0], style: .portrait)
                machineLink(machines[1], style: .portrait)
            }
        case 3:
            VStack(spacing: 10) {
                largePair(machines[0], machines[1], style: .standard)

                HStack(spacing: 10) {
                    machineLink(machines[2], style: .standard)
                    summaryLink(style: .standard)
                }
                .frame(maxHeight: .infinity)
            }
        case 4:
            VStack(spacing: 10) {
                largePair(machines[0], machines[1], style: .standard)
                largePair(machines[2], machines[3], style: .standard)
            }
        case 5:
            VStack(spacing: 10) {
                largePair(machines[0], machines[1], style: .compact)
                largePair(machines[2], machines[3], style: .compact)

                HStack(spacing: 10) {
                    machineLink(machines[4], style: .compact)
                    summaryLink(style: .compact)
                }
                .frame(maxHeight: .infinity)
            }
        case 6:
            VStack(spacing: 10) {
                largePair(machines[0], machines[1], style: .compact)
                largePair(machines[2], machines[3], style: .compact)
                largePair(machines[4], machines[5], style: .compact)
            }
        default:
            EmptyView()
        }
    }

    private func largePair(
        _ first: WidgetMachineSnapshot,
        _ second: WidgetMachineSnapshot,
        style: MyMacsTileStyle
    ) -> some View {
        HStack(spacing: 10) {
            machineLink(first, style: style)
            machineLink(second, style: style)
        }
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 7) {
            MyMacsScreenMark(connectionKind: nil, size: 21)

            Text("My Macs")
                .font(.headline)
                .fontDesign(.rounded)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: summarySymbol)
                    .foregroundStyle(summaryAccentColor)
                    .widgetAccentable()
                    .accessibilityHidden(true)

                Text(onlineLabel)

                if !showsSummaryTile {
                    Text("·")
                    Text(freshnessLabel)
                }
            }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .allowsTightening(true)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("My Macs")
        .accessibilityValue(freshnessAccessibilityLabel)
    }

    private func machineLink(
        _ machine: WidgetMachineSnapshot,
        style: MyMacsTileStyle
    ) -> some View {
        Link(destination: GlassyDeskWidgetDeepLink.connect(machine.id).url) {
            MyMacsMachineTile(machine: machine, style: style)
                .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: 44,
            maxWidth: .infinity,
            minHeight: 44,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(machine.displayName)
        .accessibilityValue(machineAccessibilityValue(machine))
        .accessibilityHint("Opens Glassy Desk and connects to this Mac")
    }

    private func summaryLink(style: MyMacsTileStyle) -> some View {
        Link(destination: GlassyDeskWidgetDeepLink.hosts.url) {
            MyMacsSummaryTile(
                title: summaryTitle,
                subtitle: freshnessLabel,
                symbolName: summarySymbol,
                style: style
            )
            .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: 44,
            maxWidth: .infinity,
            minHeight: 44,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryTitle)
        .accessibilityValue(freshnessAccessibilityLabel)
        .accessibilityHint("Opens Glassy Desk to view all Macs")
    }

    private var onlineCount: Int {
        entry.machines.filter { $0.reachability == .reachable }.count
    }

    private var allReady: Bool {
        !entry.machines.isEmpty
            && checkedDates.count == entry.machines.count
            && onlineCount == entry.machines.count
    }

    private var onlineLabel: String {
        String(localized: "\(onlineCount) online")
    }

    private var summaryTitle: String {
        allReady ? String(localized: "All ready") : onlineLabel
    }

    private var summarySymbol: String {
        allReady ? "checkmark.circle.fill" : "display.2"
    }

    private var summaryAccentColor: Color {
        renderingMode == .fullColor && onlineCount > 0 ? statusColor(.reachable) : .primary
    }

    private var showsSummaryTile: Bool {
        family == .systemLarge && (entry.machines.count == 3 || entry.machines.count == 5)
    }

    private var checkedDates: [Date] {
        entry.machines.compactMap(\.reachabilityCheckedAt)
    }

    private var freshnessLabel: String {
        guard !checkedDates.isEmpty else { return String(localized: "Not checked") }
        guard checkedDates.count == entry.machines.count else {
            return String(localized: "Partial status")
        }
        guard let freshnessDate = checkedDates.min() else { return String(localized: "Not checked") }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: min(freshnessDate, entry.date), relativeTo: entry.date)
        return String(localized: "Checked \(relative)")
    }

    private var freshnessAccessibilityLabel: String {
        guard !checkedDates.isEmpty else { return String(localized: "Status not checked") }
        guard checkedDates.count == entry.machines.count else {
            return String(localized: "Some statuses have not been checked")
        }
        guard let freshnessDate = checkedDates.min() else {
            return String(localized: "Status not checked")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: min(freshnessDate, entry.date), relativeTo: entry.date)
        return String(localized: "Status checked \(relative)")
    }

    private func machineAccessibilityValue(_ machine: WidgetMachineSnapshot) -> String {
        let connection = machine.connectionKind == .glassyStream
            ? String(localized: "Glassy Stream")
            : String(localized: "Screen Sharing")
        return "\(statusTitle(machine.reachability)), \(connection)"
    }

    private var emptyView: some View {
        ZStack(alignment: .topTrailing) {
            MyMacsScreenMark(
                connectionKind: nil,
                size: family == .systemLarge ? 150 : 92
            )
            .opacity(renderingMode == .fullColor ? 0.10 : 0.18)
            .offset(x: family == .systemLarge ? 28 : 18, y: -18)

            VStack(alignment: .leading, spacing: 7) {
                MyMacsScreenMark(
                    connectionKind: nil,
                    size: family == .systemLarge ? 54 : 38
                )

                Spacer(minLength: 12)

                Text(entry.state == .unavailable ? "Macs unavailable" : "No saved Macs")
                    .font(family == .systemLarge ? .title2.weight(.semibold) : .headline)
                    .fontDesign(.rounded)
                    .foregroundStyle(.primary)

                Text(entry.state == .unavailable
                     ? "Open Glassy Desk to manage your saved Macs."
                     : "Add a Mac, then keep it close from your Home Screen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemLarge ? 3 : 2)

                Label("Open Glassy Desk", systemImage: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .widgetAccentable()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.state == .unavailable ? "Macs unavailable" : "No saved Macs")
        .accessibilityHint("Opens Glassy Desk to manage saved Macs")
    }

    private var privacyView: some View {
        ZStack(alignment: .topTrailing) {
            MyMacsScreenMark(
                connectionKind: nil,
                size: family == .systemLarge ? 150 : 92
            )
            .opacity(renderingMode == .fullColor ? 0.08 : 0.16)
            .offset(x: family == .systemLarge ? 28 : 18, y: -18)

            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: "lock.shield.fill")
                    .font(family == .systemLarge ? .largeTitle : .title2)
                    .foregroundStyle(accentColor)
                    .widgetAccentable()
                    .accessibilityHidden(true)

                Spacer(minLength: 12)

                Text("Macs hidden")
                    .font(family == .systemLarge ? .title2.weight(.semibold) : .headline)
                    .fontDesign(.rounded)

                Text("Unlock to view names and connection status.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Macs hidden")
        .accessibilityHint("Unlock to view names and connection status")
    }

    private var accentColor: Color {
        renderingMode == .fullColor ? MyMacsPalette.accent : .primary
    }

    @ViewBuilder
    private var widgetBackground: some View {
        if renderingMode == .fullColor {
            ZStack {
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [MyMacsPalette.darkTop, MyMacsPalette.darkBottom]
                        : [MyMacsPalette.lightTop, MyMacsPalette.lightBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [MyMacsPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.09), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 240
                )
            }
        } else {
            Color.clear
        }
    }
}

private enum MyMacsTileStyle {
    case medium
    case hero
    case portrait
    case featured
    case standard
    case compact

    var isHorizontal: Bool {
        switch self {
        case .featured, .compact:
            true
        default:
            false
        }
    }

    var padding: CGFloat {
        switch self {
        case .medium:
            9
        case .compact:
            10
        default:
            13
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .medium, .compact:
            16
        default:
            18
        }
    }

    var markSize: CGFloat {
        switch self {
        case .medium:
            24
        case .compact:
            31
        case .standard:
            40
        case .featured:
            48
        case .portrait:
            62
        case .hero:
            78
        }
    }

    var nameFont: Font {
        switch self {
        case .medium, .compact:
            .system(.subheadline, design: .rounded, weight: .semibold)
        case .standard, .featured:
            .system(.headline, design: .rounded, weight: .semibold)
        case .portrait:
            .system(.title3, design: .rounded, weight: .semibold)
        case .hero:
            .system(.title2, design: .rounded, weight: .semibold)
        }
    }
}

private struct MyMacsMachineTile: View {
    let machine: WidgetMachineSnapshot
    let style: MyMacsTileStyle

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            if style.isHorizontal {
                horizontalContent
            } else {
                verticalContent
            }
        }
        .padding(style.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tileFill, in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .stroke(tileStroke, lineWidth: 0.75)
        }
        .privacySensitive()
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: style == .medium ? 3 : 7) {
            HStack(alignment: .top) {
                MyMacsScreenMark(connectionKind: machine.connectionKind, size: style.markSize)

                Spacer(minLength: 5)

                destinationSymbol
            }

            Spacer(minLength: style == .medium ? 1 : 4)

            Text(machine.displayName)
                .font(style.nameFont)
                .foregroundStyle(.primary)
                .lineLimit(2)

            MyMacsStatusLabel(status: machine.reachability)
        }
    }

    private var horizontalContent: some View {
        HStack(spacing: style == .compact ? 9 : 12) {
            MyMacsScreenMark(connectionKind: machine.connectionKind, size: style.markSize)

            VStack(alignment: .leading, spacing: 4) {
                Text(machine.displayName)
                    .font(style.nameFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                MyMacsStatusLabel(status: machine.reachability)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            destinationSymbol
        }
    }

    private var destinationSymbol: some View {
        Image(systemName: "arrow.up.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(accentColor)
            .widgetAccentable()
            .accessibilityHidden(true)
    }

    private var accentColor: Color {
        renderingMode == .fullColor ? MyMacsPalette.accent : .primary
    }

    private var tileFill: Color {
        if renderingMode == .fullColor {
            colorScheme == .dark ? .white.opacity(0.075) : .white.opacity(0.62)
        } else {
            .primary.opacity(0.07)
        }
    }

    private var tileStroke: Color {
        if renderingMode == .fullColor {
            colorScheme == .dark ? .white.opacity(0.13) : MyMacsPalette.accent.opacity(0.10)
        } else {
            .primary.opacity(0.12)
        }
    }
}

private struct MyMacsSummaryTile: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let style: MyMacsTileStyle

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            if style.isHorizontal {
                HStack(spacing: 10) {
                    summarySymbol

                    VStack(alignment: .leading, spacing: 3) {
                        summaryText
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accentColor)
                        .accessibilityHidden(true)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    summarySymbol

                    Spacer(minLength: 4)

                    summaryText
                }
            }
        }
        .padding(style.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tileFill, in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .stroke(tileStroke, lineWidth: 0.75)
        }
        .widgetAccentable()
    }

    private var summarySymbol: some View {
        Image(systemName: symbolName)
            .font(.title2.weight(.semibold))
            .foregroundStyle(accentColor)
            .accessibilityHidden(true)
    }

    private var summaryText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(style.nameFont)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .allowsTightening(true)
        }
    }

    private var accentColor: Color {
        renderingMode == .fullColor ? MyMacsPalette.accent : .primary
    }

    private var tileFill: Color {
        if renderingMode == .fullColor {
            return colorScheme == .dark
                ? MyMacsPalette.accent.opacity(0.16)
                : MyMacsPalette.accent.opacity(0.09)
        }
        return .primary.opacity(0.07)
    }

    private var tileStroke: Color {
        renderingMode == .fullColor
            ? MyMacsPalette.accent.opacity(colorScheme == .dark ? 0.28 : 0.16)
            : .primary.opacity(0.12)
    }
}

private struct MyMacsStatusLabel: View {
    let status: WidgetMachineReachability

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .accessibilityHidden(true)

            Text(compactTitle)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(foregroundColor)
        .widgetAccentable()
    }

    private var compactTitle: String {
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

    private var symbolName: String {
        switch status {
        case .unknown:
            "questionmark.circle"
        case .checking:
            "ellipsis.circle.fill"
        case .reachable:
            "checkmark.circle.fill"
        case .unreachable:
            "minus.circle.fill"
        }
    }

    private var foregroundColor: Color {
        renderingMode == .fullColor ? statusColor(status) : .primary
    }
}

private struct MyMacsScreenMark: View {
    let connectionKind: WidgetConnectionKind?
    let size: CGFloat

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                    .fill(accentColor.opacity(renderingMode == .fullColor ? 0.10 : 0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                            .stroke(accentColor.opacity(0.48), lineWidth: max(1, size * 0.025))
                    }
                    .frame(width: size * 0.76, height: size * 0.56)
                    .offset(x: size * 0.10, y: -size * 0.09)

                RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                    .fill(accentColor.opacity(renderingMode == .fullColor ? 0.18 : 0.13))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                            .stroke(accentColor.opacity(0.78), lineWidth: max(1, size * 0.025))
                    }
                    .frame(width: size * 0.76, height: size * 0.56)
                    .offset(x: -size * 0.10, y: size * 0.09)
            }

            if connectionKind == .glassyStream {
                Image(systemName: "bolt.fill")
                    .font(.system(size: max(7, size * 0.18), weight: .bold))
                    .foregroundStyle(renderingMode == .fullColor ? Color.white : Color.primary)
                    .frame(width: max(13, size * 0.30), height: max(13, size * 0.30))
                    .background(accentColor, in: Circle())
                    .offset(x: size * 0.03, y: size * 0.03)
            }
        }
        .frame(width: size, height: size * 0.78)
        .widgetAccentable()
        .accessibilityHidden(true)
    }

    private var accentColor: Color {
        renderingMode == .fullColor ? MyMacsPalette.accent : .primary
    }
}

private enum MyMacsPalette {
    static let accent = Color(red: 0.12, green: 0.43, blue: 0.93)
    static let lightTop = Color(red: 0.99, green: 0.995, blue: 1.00)
    static let lightBottom = Color(red: 0.92, green: 0.95, blue: 0.995)
    static let darkTop = Color(red: 0.055, green: 0.07, blue: 0.12)
    static let darkBottom = Color(red: 0.065, green: 0.12, blue: 0.22)
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
