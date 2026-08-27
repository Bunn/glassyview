import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    let controller: HostController

    var body: some View {
        Text(controller.runState.title)

        if controller.clientCount > 0 {
            Text("\(controller.clientCount) connected")
        }

        Divider()

        Button(controller.isStreaming ? "Stop Streaming" : "Start Streaming") {
            Task {
                await controller.toggleStreaming()
            }
        }
        .disabled(controller.isTransitioning || controller.runState == .starting)

        Button("Open Glassy Host") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit Glassy Host") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
