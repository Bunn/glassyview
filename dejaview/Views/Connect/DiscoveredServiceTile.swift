import SwiftUI

struct DiscoveredServiceTile: View {
    let service: DiscoveredService
    let isGlassyHostDetected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 14) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .background(.green.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(service.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(service.isResolved ? .subheadline.monospaced() : .subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    ReachabilityStatusBadge(status: reachabilityStatus)

                    if isGlassyHostDetected {
                        GlassyStreamDetectionBadge()
                            .accessibilityHidden(true)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: service.isResolved ? "arrow.down.left.circle.fill" : "clock")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(service.isResolved ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!service.isResolved)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .glassPanel(cornerRadius: 24, isInteractive: service.isResolved)
        .glassyStreamDetectionAccessibilityValue(isGlassyHostDetected)
        .accessibilityHint(accessibilityHint)
    }

    private var subtitle: String {
        guard let host = service.host, let port = service.port else {
            return "Resolving address..."
        }

        return "\(host):\(String(port))"
    }

    private var reachabilityStatus: MachineReachabilityStatus {
        service.isResolved ? .reachable : .checking
    }

    private var accessibilityHint: String {
        guard service.isResolved else { return "Address is still resolving." }
        return "Opens connection details."
    }
}

private extension View {
    @ViewBuilder
    func glassyStreamDetectionAccessibilityValue(_ isDetected: Bool) -> some View {
        if isDetected {
            accessibilityValue("Glassy Stream detected")
        } else {
            self
        }
    }
}
