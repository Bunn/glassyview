import AppKit
import SwiftUI

struct HostPairingView: View {
    private enum Method: String, CaseIterable { case qr = "QR Code", code = "Enter Code" }

    @Environment(\.dismiss) private var dismiss
    let controller: HostController
    @State private var method: Method = .qr
    @State private var qrImage: NSImage?
    @State private var usesLegacyQRCode = false
    @State private var hasCopiedCode = false
    @State private var startingDeviceIDs: Set<Data> = []
    @State private var connectedDeviceName: String?

    var body: some View {
        VStack(spacing: 0) {
            HostPairingIllustration()
                .frame(height: 130)
                .overlay(alignment: .topTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close pairing")
                    .keyboardShortcut(.cancelAction)
                    .padding(16)
                }

            VStack(spacing: 16) {
                if let connectedDeviceName {
                    pairedConfirmation(connectedDeviceName)
                } else {
                    VStack(spacing: 8) {
                        Text("Bring your Mac along.")
                            .font(.system(size: 25, weight: .semibold))
                        Text(method == .qr
                             ? "Open Glassy Desk on your iPhone or iPad,\nthen tap Scan QR Code."
                             : "Choose this Mac in Glassy Desk,\nthen enter the code below.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Picker("Pairing method", selection: $method) {
                        ForEach(Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if !controller.allowsConnections || controller.serverPort == nil {
                        ContentUnavailableView("Connections unavailable", systemImage: "wifi.slash", description: Text("Allow connections on this Mac, then try again."))
                            .frame(height: 268)
                    } else if method == .qr {
                        qrContent
                    } else {
                        manualCodeContent
                    }

                    Label("Connect both devices to the same Wi-Fi or VPN.", systemImage: "network")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { startingDeviceIDs = Set(controller.pairedDevices.map(\.id)) }
        .onChange(of: controller.pairedDevices) { _, devices in
            if let device = devices.first(where: { !startingDeviceIDs.contains($0.id) && $0.isConnected }) {
                connectedDeviceName = device.name
            }
        }
        .task(id: payload) {
            qrImage = nil
            guard let payload else { return }
            // The code only changes once per minute. Never redraw/validate the
            // QR image on each countdown tick or expose its contents in logs.
            qrImage = HostPairingQRCode.image(for: payload)
            hasCopiedCode = false
        }
    }

    private var qrContent: some View {
        VStack(spacing: 12) {
            if let qrImage {
                Image(nsImage: qrImage)
                    .resizable().interpolation(.none)
                    .frame(width: 300, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel("Pairing QR code for \(HostIdentity.name)")
                    .privacySensitive()
            } else if payload == nil {
                ContentUnavailableView("Use a pairing code", systemImage: "qrcode", description: Text("A network address isn’t available yet. Connect this Mac to Wi-Fi or your VPN, then try again."))
                    .frame(height: 268)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "qrcode").font(.largeTitle)
                    Text("QR code unavailable. Choose Enter Code to pair.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(height: 268)
            }
            expirationLabel

            VStack(spacing: 6) {
                Toggle("Older Glassy Desk", isOn: $usesLegacyQRCode)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityHint("Shows a QR code compatible with older Glassy Desk releases")
                Text("Use this if Glassy Desk says the QR code isn’t valid. Update Glassy Desk for automatic Wi-Fi and VPN route selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    private var manualCodeContent: some View {
        VStack(spacing: 22) {
            Image(systemName: "keyboard").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Text(HostIdentity.name).font(.headline)
                Text(HostProtocol.pairingCodeDisplayValue(controller.pairingCode))
                    .font(.system(size: 25, weight: .medium, design: .monospaced))
                    .textSelection(.enabled).privacySensitive()
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Button(hasCopiedCode ? "Copied" : "Copy Code", systemImage: hasCopiedCode ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controller.pairingCode, forType: .string)
                hasCopiedCode = true
            }
            .buttonStyle(.bordered)
            .disabled(controller.pairingCodeExpiresAt == nil)
            expirationLabel
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
    }

    private var expirationLabel: some View {
        Label("Refreshes automatically in \(controller.pairingCodeRemainingSeconds)s", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            .accessibilityLabel("Pairing code refreshes automatically every minute")
    }

    private func pairedConfirmation(_ name: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green)
            Text("You’re connected.").font(.title.weight(.semibold))
            Text("\(name) can now access this Mac. You can manage its access in Connections.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .modifier(HostPrimaryActionStyle()).controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 350)
    }

    private var payload: String? {
        guard controller.allowsConnections,
              let host = controller.pairingAddresses.first,
              let hostIdentifier = controller.pairingHostIdentifier,
              let port = controller.serverPort,
              let expiration = controller.pairingCodeExpiresAt else { return nil }
        let invite = HostPairingInvite(
            host: host, port: port, name: HostIdentity.name,
            code: controller.pairingCode, expiresAt: expiration,
            hostIdentifier: hostIdentifier,
            alternateHosts: Array(controller.pairingAddresses.dropFirst())
        )
        return usesLegacyQRCode ? invite.legacyURLString : invite.urlString
    }
}
