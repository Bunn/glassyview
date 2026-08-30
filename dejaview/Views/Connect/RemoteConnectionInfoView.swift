import SwiftUI

struct RemoteConnectionInfoView: View {
    var body: some View {
        Form {
            Section {
                Label {
                    Text("For the easiest secure connection outside your local network, use Tailscale on the iPad and the remote Mac.")
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.blue)
                }
            }

            Section("Recommended Setup") {
                setupStep(
                    "Install Tailscale",
                    detail: "Install and open Tailscale on both this device and the remote Mac.",
                    systemImage: "arrow.down.app.fill"
                )

                setupStep(
                    "Join the Same Tailnet",
                    detail: "Sign in so both devices appear on the same private Tailscale network.",
                    systemImage: "network"
                )

                setupStep(
                    "Enter the Mac’s Address",
                    detail: "Add the Mac manually using its Tailscale IP address or full .ts.net name.",
                    systemImage: "desktopcomputer"
                )
            }

            Section {
                Label {
                    Text("Nearby discovery only finds Macs on the current local network. Tailscale reaches the remote Mac without exposing a public port on your router.")
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Remote Connections")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setupStep(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
        }
    }
}
