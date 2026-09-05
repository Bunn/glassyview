import SwiftUI

struct GlassyStreamSetupView: View {
    let scan: () -> Void
    let pairManually: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    MacPairingIllustration()
                        .scaleEffect(0.8)
                        .frame(height: 200)
                    Text("Make the fast connection.")
                        .font(.title.bold())
                        .tracking(-0.8)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Set up Glassy Desk once.\nYour Mac will be ready whenever you are.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        instruction(number: "1", title: "Install Glassy Desk for Mac",
                                    detail: "The companion app powers your connection.")
                        GlassyHostDownloadLink()
                            .padding(.leading, 42)
                    }
                    instruction(number: "2", title: "Open Add Device on your Mac",
                                detail: "Keep its pairing code on the screen.")
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))

                Text("Use the same Wi-Fi network, or connect your VPN.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Button {
                    scan()
                } label: {
                    Label("Scan Mac’s Code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("connection.glassy-stream.scan")

                Button("Pair Manually") {
                    pairManually()
                }
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .accessibilityIdentifier("connection.glassy-stream.manual-options")
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
        }
        .navigationTitle("Fast Connection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func instruction(number: String, title: LocalizedStringKey,
                             detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.09), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

}

#Preview("Set Up Fast Connection") {
    NavigationStack {
        GlassyStreamSetupView(scan: {}, pairManually: {})
    }
}
