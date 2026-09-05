import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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

        Settings {
            HostSettingsView(controller: controller, updater: updater)
        }

        MenuBarExtra {
            MenuBarContentView(controller: controller, updater: updater)
        } label: {
            Label("Glassy Desk", systemImage: controller.menuBarSystemImage)
                .task {
                    // A visual preview must not read pairing credentials,
                    // serve connections, or start the production updater.
                    guard !isLocalPreview else { return }
                    updater.startIfConfigured()
                    // The listener lifecycle belongs to the menu-bar host, not
                    // to whether the dashboard window happens to be open.
                    await controller.prepare()
                }
        }
    }

    private var isLocalPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--glassy-preview")
        #else
        false
        #endif
    }

    private var dashboardWindow: some Scene {
        WindowGroup("Glassy Desk", id: "main") {
            HostDashboardView(controller: controller)
                .frame(minWidth: 820, minHeight: 620)
                .task {
                    guard !isLocalPreview else { return }
                    await controller.prepare()
                }
        }
        .defaultSize(width: 980, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
        }
    }
}
