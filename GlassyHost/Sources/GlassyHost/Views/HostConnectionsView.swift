import SwiftUI

struct HostConnectionsView: View {
    @Bindable var controller: HostController
    let addDevice: () -> Void
    @State private var deviceToRevoke: HostPairedDevice?
    @State private var isPauseConfirmationPresented = false

    var body: some View {
        HostPageHeading(title: "Your Mac, within reach.", subtitle: "Share your Mac with your iPhone or iPad.")

        HStack(spacing: 16) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 76, height: 68)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(HostIdentity.name).font(.title3.weight(.semibold))
                HostAvailabilityLabel(controller: controller).font(.callout)
            }
            Spacer()
        }

        VStack(alignment: .leading, spacing: 12) {
            Text("Devices that can access this Mac").font(.headline)
            HostContentCard {
                Toggle(isOn: connectionBinding) {
                    HostSettingLabel(title: "Allow connections", detail: "Only devices you pair can access your Mac.", symbol: "network")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .accessibilityLabel("Allow connections")
                .padding(.vertical, 18)
                .disabled(controller.isUpdatingConnectionAccess)
                Divider()
                if controller.pairedDevices.isEmpty {
                    emptyDevices
                } else {
                    ForEach(controller.pairedDevices) { device in
                        if device.id != controller.pairedDevices.first?.id { Divider() }
                        deviceRow(device)
                    }
                }
            }
        }

        if !controller.permissions.canCaptureScreen || controller.accessibilityAuthorization != .granted {
            HostPermissionsView(controller: controller, compact: true)
        }

        if let error = controller.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }

        HostContentCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Local address", value: HostIdentity.address ?? "Unavailable")
                    LabeledContent("Port", value: controller.serverPort.map(String.init) ?? "Offline")
                    Text("Use the same Wi-Fi network for QR pairing. Away from home, use your Mac’s Tailscale address in Glassy Desk.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                .padding(.top, 14)
            } label: {
                Label("Connection details", systemImage: "info.circle")
            }
            .padding(.vertical, 18)
        }

        Label("Connections are encrypted. Your screen is shared only when a paired device connects, unless you start sharing manually.", systemImage: "lock.shield")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .alert("Revoke access?", isPresented: revokeBinding, presenting: deviceToRevoke) { device in
                Button("Cancel", role: .cancel) { deviceToRevoke = nil }
                Button("Revoke Access", role: .destructive) {
                    Task { await controller.revokeDevice(id: device.id) }
                    deviceToRevoke = nil
                }
            } message: { device in
                Text("\(device.name) will be disconnected and will need to pair again to access this Mac.")
            }
            .alert("Pause connections?", isPresented: $isPauseConfirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Pause Connections", role: .destructive) {
                    Task { await controller.setAllowsConnections(false) }
                }
            } message: {
                Text("Connected devices will be disconnected and screen sharing will stop. You can allow connections again at any time.")
            }
    }

    private var emptyDevices: some View {
        VStack(spacing: 12) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Make your first connection").font(.headline)
            Text("Scan a QR code to securely pair your iPhone or iPad.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Add Device", systemImage: "plus", action: addDevice)
                .modifier(HostPrimaryActionStyle()).controlSize(.large)
                .disabled(!controller.allowsConnections || controller.serverPort == nil)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func deviceRow(_ device: HostPairedDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone")
                .font(.system(size: 22)).foregroundStyle(.secondary)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.body.weight(.medium)).lineLimit(2)
                if device.isConnected {
                    Label("Connected", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
                } else {
                    Text("Last connected \(device.lastConnectedAt, style: .relative) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("Revoke Access…") { deviceToRevoke = device }
                .controlSize(.small)
                .disabled(controller.isUpdatingConnectionAccess)
                .accessibilityLabel("Revoke access for \(device.name)")
        }
        .padding(.vertical, 17)
    }

    private var connectionBinding: Binding<Bool> {
        Binding(get: { controller.allowsConnections }, set: { allowed in
            if !allowed && (controller.clientCount > 0 || controller.isStreaming) {
                isPauseConfirmationPresented = true
            } else {
                Task { await controller.setAllowsConnections(allowed) }
            }
        })
    }

    private var revokeBinding: Binding<Bool> {
        Binding(get: { deviceToRevoke != nil }, set: { if !$0 { deviceToRevoke = nil } })
    }
}
