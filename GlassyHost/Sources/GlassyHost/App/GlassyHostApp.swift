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
            Label("Glassy Host", systemImage: controller.menuBarSystemImage)
                .task {
                    // Local UI previews must not query the production feed or
                    // show Sparkle's first-launch preference prompt.
                    if !isLocalPreview {
                        updater.startIfConfigured()
                    }
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
        WindowGroup("Glassy Host", id: "main") {
            HostDashboardView(controller: controller)
                .frame(minWidth: 820, minHeight: 620)
                .task {
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
