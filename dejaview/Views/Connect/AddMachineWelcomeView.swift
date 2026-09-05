import SwiftUI

/// Choose the connection technology first; pairing choices belong to Glassy Stream.
struct AddMachineWelcomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let useGlassyStream: () -> Void
    let useVNC: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Mac.\nYour way.")
                            .font(.largeTitle.bold())
                            .tracking(-0.8)
                            .accessibilityAddTraits(.isHeader)
                        Text("Two ways to connect.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !dynamicTypeSize.isAccessibilitySize {
                        MacPairingIllustration()
                            .scaleEffect(0.52)
                            .frame(width: 146, height: 146)
                    }
                }
                .padding(.top, 8)

                glassyStreamCard
                vncCard
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Add Mac")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var glassyStreamCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Fast Connection")
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Recommended")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Much faster, smoother control than standard VNC.")
                    .font(.subheadline.weight(.medium))
                Text("Requires Glassy Desk for Mac. Download once, then pair by QR code or manually.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(action: useGlassyStream) {
                HStack(spacing: 8) {
                    Text("Set Up Fast Connection")
                    Image(systemName: "arrow.right")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("connection.add-mac.glassy-stream")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 1)
        }
    }

    private var vncCard: some View {
        Button(action: useVNC) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Standard VNC")
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Text("Uses built-in macOS Screen Sharing. No extra download needed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(20)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Set up a standard VNC connection using your Mac login.")
        .accessibilityIdentifier("connection.add-mac.screen-sharing")
    }
}

#Preview("Choose a Connection") {
    NavigationStack {
        AddMachineWelcomeView(useGlassyStream: {}, useVNC: {})
    }
}
