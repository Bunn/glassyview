import SwiftUI

struct HostPermissionsView: View {
    let controller: HostController
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(compact ? "Finish setting up your Mac" : "Permissions").font(.headline)
            HostContentCard {
                if !compact || controller.screenRecordingAuthorization != .granted {
                    permissionRow(title: "Screen Recording", detail: "See this Mac’s display on your device.", symbol: "rectangle.inset.filled.and.person.filled", allowed: controller.screenRecordingAuthorization == .granted, allow: controller.requestScreenRecordingPermission, settings: controller.openScreenRecordingSettings)
                }
                if !compact || (controller.screenRecordingAuthorization != .granted && controller.accessibilityAuthorization != .granted) { Divider() }
                if !compact || controller.accessibilityAuthorization != .granted {
                    permissionRow(title: "Accessibility", detail: "Use your device’s keyboard and pointer.", symbol: "cursorarrow.motionlines", allowed: controller.accessibilityAuthorization == .granted, allow: controller.requestAccessibilityPermission, settings: controller.openAccessibilitySettings)
                }
            }
        }
    }

    private func permissionRow(title: String, detail: String, symbol: String, allowed: Bool, allow: @escaping () -> Void, settings: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            HostSettingLabel(title: title, detail: detail, symbol: symbol)
            Spacer(minLength: 12)
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            } else {
                Button("Allow…", action: allow)
                    .accessibilityLabel("Allow \(title)")
                Button(action: settings) { Image(systemName: "gearshape") }
                    .help("Open \(title) in System Settings")
                    .accessibilityLabel("Open \(title) in System Settings")
            }
        }
        .padding(.vertical, 18)
    }
}
