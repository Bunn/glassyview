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
    @State private var controller = HostController()

    var body: some Scene {
        dashboardWindow

        MenuBarExtra {
            MenuBarContentView(controller: controller)
        } label: {
            Label("Glassy Host", systemImage: controller.menuBarSystemImage)
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
    }
}
