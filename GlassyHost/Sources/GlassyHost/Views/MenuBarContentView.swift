import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    let controller: HostController
    let updater: HostUpdateController

    var body: some View {
        Text(controller.runState.title)

        if controller.clientCount > 0 {
            Text("\(controller.clientCount) connected")
        }

        Text(controller.isStreaming ? "Screen sharing is active" : "Screen sharing is idle")

        Divider()

        if controller.isOnDemandStreaming {
            Button("Keep Sharing") {
                Task {
                    await controller.keepStreamingAfterDisconnect()
                }
            }
            .disabled(controller.isTransitioning)
        }

        Button(controller.isStreaming ? "Stop Sharing" : "Share Continuously") {
            Task {
                await controller.toggleStreaming()
            }
        }
        .disabled(!controller.allowsConnections || controller.serverPort == nil || controller.isTransitioning)

        Button("Open Glassy Desk") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        CheckForUpdatesView(updater: updater)
        if updater.isInstallationDeferred {
            Text("Update waits for disconnect")
        }

        Divider()

        Button("Quit Glassy Desk") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
