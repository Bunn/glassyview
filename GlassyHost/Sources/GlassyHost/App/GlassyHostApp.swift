import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

@main
struct GlassyHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller: HostController
    @State private var updater: HostUpdateController

    init() {
        let controller = HostController()
        _controller = State(initialValue: controller)
        _updater = State(initialValue: HostUpdateController(
            hasActiveSessions: { [weak controller] in
                (controller?.clientCount ?? 0) > 0
            }
        ))
    }

    var body: some Scene {
        dashboardWindow

        MenuBarExtra {
            MenuBarContentView(controller: controller, updater: updater)
        } label: {
            Label("Glassy Host", systemImage: controller.menuBarSystemImage)
                .task {
                    updater.startIfConfigured()
                    // The listener lifecycle belongs to the menu-bar host, not
                    // to whether the dashboard window happens to be open.
                    await controller.prepare()
                }
        }
    }

    private var dashboardWindow: some Scene {
        WindowGroup("Glassy Host", id: "main") {
            HostDashboardView(controller: controller)
                .frame(minWidth: 560, minHeight: 500)
                .task {
                    await controller.prepare()
                }
        }
        .defaultSize(width: 620, height: 600)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
        }
    }
}
