import SwiftUI

enum HostIdentity {
    static var name: String {
        let rawName = Host.current().localizedName ?? "This Mac"
        let scalars = rawName.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
                && !(0x202A...0x202E).contains($0.value)
                && !(0x2066...0x2069).contains($0.value)
        }
        var name = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 255 { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "This Mac" : name
    }
    static var address: String? { HostPairingInvite.localHostAddress() }
}

struct HostPrimaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct HostContentCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 20)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct HostPageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold))
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct HostAvailabilityLabel: View {
    let controller: HostController

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(color)
            .accessibilityLabel("Host status: \(title)")
    }

    private var title: String {
        if !controller.allowsConnections { return "Connections paused" }
        if controller.isStreaming { return "Sharing your screen" }
        switch controller.runState {
        case .ready: return "Ready to connect"
        case .starting: return "Getting ready…"
        case .stopped: return "Offline"
        case .failed: return "Needs attention"
        }
    }

    private var symbol: String {
        if !controller.allowsConnections { return "pause.circle.fill" }
        if case .failed = controller.runState { return "exclamationmark.circle.fill" }
        return controller.isStreaming ? "record.circle" : "circle.inset.filled"
    }

    private var color: Color {
        if !controller.allowsConnections { return .secondary }
        if case .failed = controller.runState { return .orange }
        return controller.serverPort == nil ? .secondary : .green
    }
}

struct HostSettingLabel: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
