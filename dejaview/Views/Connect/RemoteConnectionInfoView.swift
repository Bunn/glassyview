import SwiftUI

struct RemoteConnectionInfoView: View {
    var body: some View {
        Form {
            Section {
                Label {
                    Text("Glassy Desk automatically finds a working connection over your local network or a VPN such as Tailscale or WireGuard.")
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.blue)
                }
            }

            Section("Connect from Another Network") {
                setupStep(
                    "Connect Your VPN",
                    detail: "Connect this device and the Mac with Tailscale or WireGuard so they can reach each other.",
                    systemImage: "network"
                )

                setupStep(
                    "Open Add Device on the Mac",
                    detail: "Glassy Desk includes the Mac’s current local and VPN addresses in its pairing QR code.",
                    systemImage: "desktopcomputer"
                )

                setupStep(
                    "Scan and Connect",
                    detail: "Choose Add Mac → Set Up Fast Connection in Glassy Desk, scan the code, and confirm the Mac. Its saved addresses work automatically when you change networks.",
                    systemImage: "qrcode.viewfinder"
                )
            }

            Section {
                Label {
                    Text("Nearby discovery finds Macs on your local network. Use a QR code or a saved VPN address to connect from elsewhere. If the Mac’s VPN setup changes after pairing, scan a new QR code to refresh its addresses.")
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
