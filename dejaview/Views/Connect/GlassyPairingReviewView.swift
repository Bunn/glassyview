import SwiftUI

@MainActor
struct GlassyPairingReviewView: View {
    let invitation: GlassyHostPairingInvitation
    let isPairing: Bool
    let pair: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Connect to \(invitation.name)?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(invitation.candidate.detail)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Confirm this is the Mac you want to view and control. Only scan a code shown on a Mac you trust.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = context.date >= invitation.expiresAt
                VStack(spacing: 12) {
                    if expired {
                        Label("Code expired. Scan the new code on your Mac.",
                              systemImage: "clock.badge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        pair()
                    } label: {
                        HStack {
                            if isPairing { ProgressView() }
                            Text(isPairing ? "Connecting…" : "Pair & Connect")
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(expired || isPairing)
                    .accessibilityIdentifier("connection.glassy-stream.qr-confirm")
                }
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Review Mac") {
    let expiration = Int(Date.now.timeIntervalSince1970) + 60
    let invitation = try? GlassyHostPairingInvitation(scannedValue:
        "glassydesk://pair?v=1&host=Studio-Mac.local&port=51515&name=Studio%20Mac&code=ABCD2345EFGH&expires=\(expiration)"
    )
    NavigationStack {
        Form {
            if let invitation {
                Section {
                    GlassyPairingReviewView(invitation: invitation, isPairing: false, pair: {})
                }
            }
        }
        .navigationTitle("Pair Glassy Stream")
        .navigationBarTitleDisplayMode(.inline)
    }
}
