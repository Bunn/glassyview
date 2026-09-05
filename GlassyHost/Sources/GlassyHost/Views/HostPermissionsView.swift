import SwiftUI

struct HostPermissionsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let controller: HostController
    var compact = false

    private var screenRecordingAllowed: Bool {
        controller.screenRecordingAuthorization == .granted
    }

    private var accessibilityAllowed: Bool {
        controller.accessibilityAuthorization == .granted
    }

    private var allowedCount: Int {
        (screenRecordingAllowed ? 1 : 0) + (accessibilityAllowed ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(compact ? "Finish setting up your Mac" : "Permissions")
                    .font(.headline)
                Spacer()
                Text(allowedCount == 2 ? "Ready to share" : "\(allowedCount) of 2 allowed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(allowedCount == 2 ? Color.green : Color.secondary)
                    .monospacedDigit()
            }

            HostContentCard {
                if allowedCount < 2 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A quick setup for your screen, keyboard, and pointer.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(allowedCount), total: 2)
                            .accessibilityLabel("Permission setup")
                            .accessibilityValue("\(allowedCount) of 2 permissions allowed")
                    }
                    .padding(.top, 20)
                }

                permissionRow(
                    title: "Screen Recording",
                    detail: "See this Mac’s display on your device.",
                    symbol: "rectangle.inset.filled.and.person.filled",
                    allowed: screenRecordingAllowed,
                    allow: controller.requestScreenRecordingPermission
                )
                Divider()
                permissionRow(
                    title: "Accessibility",
                    detail: "Use your device’s keyboard and pointer.",
                    symbol: "cursorarrow.motionlines",
                    allowed: accessibilityAllowed,
                    allow: controller.requestAccessibilityPermission
                )
            }

            if allowedCount < 2 {
                Label {
                    Text("Turn on Glassy Desk in System Settings. If it’s missing, drag the app from the floating guide into the list. Your progress updates when you return.")
                } icon: {
                    Image(systemName: "hand.draw")
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if !screenRecordingAllowed {
                    Text("If macOS asks you to quit and reopen Glassy Desk, do so to finish enabling Screen Recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: allowedCount)
    }

    private func permissionRow(
        title: String,
        detail: String,
        symbol: String,
        allowed: Bool,
        allow: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            HostSettingLabel(title: title, detail: detail, symbol: symbol)
            Spacer(minLength: 12)
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .fixedSize()
                    .accessibilityLabel("\(title) allowed")
            } else {
                Button("Enable…", systemImage: "arrow.up.forward", action: allow)
                    .modifier(HostPrimaryActionStyle())
                    .fixedSize()
                    .help("Open a guide to enable \(title) in System Settings")
                    .accessibilityLabel("Enable \(title)")
            }
        }
        .padding(.vertical, 18)
    }
}
