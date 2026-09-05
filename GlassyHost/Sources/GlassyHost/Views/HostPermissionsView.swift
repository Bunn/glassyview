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
            + (controller.permissions.canCaptureScreen ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(compact ? "Finish setting up your Mac" : "Permissions")
                    .font(.headline)
                Spacer()
                Text(allowedCount == 3 ? "Ready to share" : "\(allowedCount) of 3 complete")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(allowedCount == 3 ? Color.green : Color.secondary)
                    .monospacedDigit()
            }

            HostContentCard {
                if allowedCount < 3 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A quick setup for your screen, keyboard, and pointer.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(allowedCount), total: 3)
                            .accessibilityLabel("Permission setup")
                            .accessibilityValue("\(allowedCount) of 3 permission steps complete")
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
                Divider()
                permissionRow(
                    title: "Direct Screen Access",
                    detail: "Confirm access before your first connection. Choose Allow when macOS asks to bypass the system private window picker.",
                    symbol: "checkmark.shield",
                    allowed: controller.permissions.canCaptureScreen,
                    allow: controller.requestDirectScreenAccessPermission,
                    actionTitle: "Confirm…",
                    completionTitle: "Confirmed",
                    isBusy: controller.permissions.isConfirmingScreenAccess,
                    isEnabled: screenRecordingAllowed && !controller.permissions.isRefreshing
                )
            }

            if allowedCount < 3 {
                Label {
                    Text("Enable Screen Recording and Accessibility in System Settings, then confirm Direct Screen Access here. Glassy Desk shares your display only, even when macOS mentions audio.")
                } icon: {
                    Image(systemName: "hand.draw")
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = controller.permissions.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Check Again", systemImage: "arrow.clockwise") {
                    Task { await controller.refreshAuthorizationStatuses() }
                }
                .disabled(controller.permissions.isRefreshing || controller.permissions.isConfirmingScreenAccess)
                if controller.permissions.isRefreshing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Checking permissions")
                } else {
                    Text("Permissions also update when you return to Glassy Desk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await controller.refreshAuthorizationStatuses() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: allowedCount)
    }

    private func permissionRow(
        title: String,
        detail: String,
        symbol: String,
        allowed: Bool,
        allow: @escaping () -> Void,
        actionTitle: String = "Enable…",
        completionTitle: String = "Allowed",
        isBusy: Bool = false,
        isEnabled: Bool = true
    ) -> some View {
        HStack(spacing: 12) {
            HostSettingLabel(title: title, detail: detail, symbol: symbol)
            Spacer(minLength: 12)
            if allowed {
                Label(completionTitle, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .fixedSize()
                    .accessibilityLabel("\(title) allowed")
            } else if isBusy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Confirming \(title)")
            } else {
                Button(actionTitle, systemImage: "arrow.up.forward", action: allow)
                    .modifier(HostPrimaryActionStyle())
                    .fixedSize()
                    .disabled(!isEnabled)
                    .help(title == "Direct Screen Access"
                          ? "Briefly check screen access locally and show the macOS approval dialog if needed"
                          : "Open a guide to enable \(title) in System Settings")
                    .accessibilityLabel("\(actionTitle.replacingOccurrences(of: "…", with: "")) \(title)")
            }
        }
        .padding(.vertical, 18)
    }
}
