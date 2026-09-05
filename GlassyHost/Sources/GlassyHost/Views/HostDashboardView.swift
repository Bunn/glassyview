import AppKit
import SwiftUI

struct HostDashboardView: View {
    private enum Destination: String, CaseIterable, Identifiable {
        case connections = "Connections"
        case display = "Display & Control"
        var id: Self { self }
        var symbol: String { self == .connections ? "laptopcomputer.and.iphone" : "display" }
    }

    @Bindable var controller: HostController
    @SceneStorage("host.dashboard.destination") private var savedDestination = Destination.connections.rawValue
    @State private var isPairingPresented = false

    private var selection: Binding<Destination?> {
        Binding(
            get: { Destination(rawValue: savedDestination) ?? .connections },
            set: { if let value = $0 { savedDestination = value.rawValue } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("This Mac") {
                    ForEach(Destination.allCases) { destination in
                        Label(destination.rawValue, systemImage: destination.symbol)
                            .tag(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 18) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Glassy Desk").font(.headline)
                        Text("Your Mac, ready to share.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 16) {
                    HostAvailabilityLabel(controller: controller)
                    SettingsLink {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 270)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if selection.wrappedValue == .display {
                        HostDisplayView(controller: controller)
                    } else {
                        HostConnectionsView(controller: controller) {
                            isPairingPresented = true
                        }
                    }
                }
                .frame(maxWidth: 720)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .navigationTitle(selection.wrappedValue?.rawValue ?? "Connections")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Device", systemImage: "plus") { isPairingPresented = true }
                        .labelStyle(.titleAndIcon)
                        .modifier(HostPrimaryActionStyle())
                        .keyboardShortcut("n", modifiers: .command)
                        .disabled(!controller.allowsConnections || controller.serverPort == nil)
                        .help("Connect an iPhone or iPad with Glassy Desk")
                }
            }
        }
        .sheet(isPresented: $isPairingPresented) { HostPairingView(controller: controller) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshLoginItemStatus()
            controller.refreshAuthorizationStatuses()
        }
    }
}
