import AppKit

enum HostDockIconPreference {
    static let defaultsKey = "hideDockIcon"

    @MainActor
    static func apply(isHidden: Bool) {
        // Keep the current window usable when macOS removes or restores the
        // Dock icon. The menu bar extra remains available in either mode.
        let keyWindow = NSApp.keyWindow
        NSApp.setActivationPolicy(isHidden ? .accessory : .regular)
        NSApp.activate(ignoringOtherApps: true)
        keyWindow?.makeKeyAndOrderFront(nil)
    }
}
