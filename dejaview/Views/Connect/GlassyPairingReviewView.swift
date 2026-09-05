import SwiftUI

@MainActor
struct GlassyPairingReviewView: View {
    let invitation: GlassyHostPairingInvitation
    let isPairing: Bool
    let pair: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            MacPairingIllustration(isRecognized: true)

            VStack(spacing: 8) {
                Text("There’s your Mac.")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Make sure this is the Mac you want to view and control.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Text(invitation.name)
                    .font(.title3.weight(.semibold))
                Text(invitation.candidate.detail)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if invitation.addresses.count > 1 {
                    Label("Wi-Fi and VPN routes included", systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))

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
                            if isPairing { ProgressView().tint(.white) }
                            Text(isPairing ? "Connecting…" : "Pair & Connect")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(expired || isPairing)
                    .accessibilityIdentifier("connection.glassy-stream.qr-confirm")
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Review Mac") {
    let expiration = Int(Date.now.timeIntervalSince1970) + 60
    let invitation = try? GlassyHostPairingInvitation(scannedValue:
        "glassydesk://pair?v=1&host=Studio-Mac.local&port=51515&name=Studio%20Mac&code=ABCD2345EFGH&expires=\(expiration)"
    )
    NavigationStack {
        ScrollView {
            if let invitation {
                GlassyPairingReviewView(invitation: invitation, isPairing: false, pair: {})
                    .padding(24)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Scan Mac’s Code")
        .navigationBarTitleDisplayMode(.inline)
    }
}
