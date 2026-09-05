import AppKit
import SwiftUI

struct HostSettingsView: View {
    @Bindable var controller: HostController
    let updater: HostUpdateController
    @State private var isPasswordEditorPresented = false
    @State private var isRemovePasswordPresented = false
    @State private var isResetPresented = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            security.tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(width: 540, height: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshLoginItemStatus()
        }
        .sheet(isPresented: $isPasswordEditorPresented) { PairingPasswordEditorView(controller: controller) }
        .alert("Remove pairing password?", isPresented: $isRemovePasswordPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Password", role: .destructive) { Task { await controller.removePairingPassword() } }
        } message: {
            Text("New devices can still pair with a QR code or rotating code. Paired devices will keep their access.")
        }
        .alert("Reset all device access?", isPresented: $isResetPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Access", role: .destructive) { Task { await controller.replacePairingKey() } }
        } message: {
            Text("Every device will need to pair again. Your pairing key will be replaced and the optional password removed.")
        }
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Open Glassy Desk at login", isOn: Binding(get: { controller.startsAtLogin }, set: { controller.setStartsAtLogin($0) }))
                    .disabled(controller.isUpdatingLoginItem)
                switch controller.loginItemStatus {
                case .requiresApproval:
                    LabeledContent("Approval required") {
                        Button("Open Login Items", action: controller.openLoginItemSettings)
                    }
                case .notFound:
                    Text("Move Glassy Desk to Applications to enable login items.")
                        .foregroundStyle(.secondary)
                default: EmptyView()
                }
                if let error = controller.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Glassy Desk stays available in the menu bar when you close its window.")
            }
            Section("Software updates") {
                LabeledContent("Glassy Desk", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                CheckForUpdatesView(updater: updater)
            }
        }
        .formStyle(.grouped)
    }

    private var security: some View {
        Form {
            Section {
                LabeledContent("Pairing password", value: controller.isLoadingPairingPassword
                               ? "Checking Keychain…"
                               : (controller.isPairingPasswordConfigured ? "Enabled" : "Not set"))
                HStack {
                    Button(controller.isPairingPasswordConfigured ? "Change Password…" : "Set Password…") { isPasswordEditorPresented = true }
                    if controller.isPairingPasswordConfigured {
                        Button("Remove…") { isRemovePasswordPresented = true }
                    }
                }
                .disabled(controller.isUpdatingPairingPassword || controller.isLoadingPairingPassword)
                if let error = controller.pairingPasswordError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Optional password")
            } footer: {
                Text("QR codes are the easiest way to pair nearby. A reusable password is available for remote pairing over Tailscale.")
            }
            Section {
                Button("Reset All Device Access…", role: .destructive) { isResetPresented = true }
                    .disabled(controller.isUpdatingPairingPassword || controller.isUpdatingConnectionAccess)
            } header: {
                Text("Device access")
            } footer: {
                Text("To remove just one device, revoke its access in Connections.")
            }
        }
        .formStyle(.grouped)
    }
}
