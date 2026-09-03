import SwiftUI

struct HostDisplayView: View {
    @Bindable var controller: HostController

    var body: some View {
        HostPageHeading(title: "A familiar view. From anywhere.", subtitle: "Choose what to share and how your device can control it.")
        HostContentCard {
            HStack(spacing: 20) {
                HostSettingLabel(title: "Shared display", detail: "Choose the screen your devices will see.", symbol: "display")
                Spacer()
                if controller.displays.isEmpty {
                    Text(controller.displayName).foregroundStyle(.secondary)
                } else {
                    Picker("Shared display", selection: $controller.selectedDisplayID) {
                        ForEach(controller.displays) { display in
                            Text(display.isMain ? "\(display.name) (Main)" : display.name).tag(Optional(display.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 220)
                    .disabled(controller.isStreaming || controller.isTransitioning)
                }
            }
            .padding(.vertical, 20)
        }

        VStack(alignment: .leading, spacing: 12) {
            Text("Screen sharing").font(.headline)
            HostContentCard {
                VStack(alignment: .leading, spacing: 18) {
                    HostSettingLabel(title: controller.isStreaming ? "Your screen is being shared" : "Ready when you are", detail: controller.captureStatusText, symbol: controller.isStreaming ? "record.circle" : "play.display")
                    Divider()
                    Text("Sharing starts automatically when a paired device connects and stops shortly after the last device disconnects. You can also keep sharing continuously.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if controller.isOnDemandStreaming {
                            Button("Keep Sharing") { Task { await controller.keepStreamingAfterDisconnect() } }
                                .disabled(controller.isTransitioning)
                        }
                        Spacer()
                        Button(controller.isStreaming ? "Stop Sharing" : "Share Continuously") {
                            Task { await controller.toggleStreaming() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!controller.allowsConnections || controller.serverPort == nil || controller.isTransitioning)
                    }
                }
                .padding(.vertical, 20)
            }
        }
        HostPermissionsView(controller: controller)
        if let error = controller.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
        }
    }
}
