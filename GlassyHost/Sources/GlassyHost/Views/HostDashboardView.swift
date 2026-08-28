import AppKit
import SwiftUI

struct HostDashboardView: View {
    @Bindable var controller: HostController
    @State private var isResetConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                streamingSection
                startupSection
                pairingSection
                securityNote
            }
            .padding(24)
        }
        .background(.background)
        .alert("Replace Pairing Key?", isPresented: $isResetConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Replace Key", role: .destructive) {
                controller.replacePairingKey()
            }
        } message: {
            Text("Devices paired with the current key will need to pair again.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshLoginItemStatus()
            controller.refreshAuthorizationStatuses()
        }
    }

    private var startupSection: some View {
        GroupBox("Startup") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Start Glassy Host when I log in",
                    isOn: Binding(
                        get: { controller.startsAtLogin },
                        set: { controller.setStartsAtLogin($0) }
                    )
                )
                .disabled(controller.isUpdatingLoginItem)

                switch controller.loginItemStatus {
                case .notRegistered:
                    Text("Glassy Host won’t open automatically.")
                        .foregroundStyle(.secondary)
                case .enabled:
                    Label("Glassy Host will open automatically when you log in.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .requiresApproval:
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label("Approval is required in System Settings.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") {
                            controller.openLoginItemSettings()
                        }
                    }
                case .notFound:
                    Label("Registration is not available from this copy yet. Move Glassy Host to Applications, then try again.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                if let loginItemError = controller.loginItemError {
                    Label(loginItemError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)
            .padding(4)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .frame(width: 58, height: 58)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text("Glassy Host")
                    .font(.title2.weight(.semibold))
                Text("Low-latency streaming for Glassy Desk")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(state: controller.runState)
        }
    }

    private var streamingSection: some View {
        GroupBox("Streaming") {
            VStack(spacing: 0) {
                statusRow("Host Listener",
                          value: controller.runState.title,
                          systemImage: "network",
                          color: controller.runState == .ready ? .green : .secondary)

                Divider()

                statusRow("Screen Recording",
                          value: controller.screenRecordingAuthorization.title,
                          systemImage: "rectangle.inset.filled.and.person.filled",
                          color: controller.screenRecordingAuthorization == .granted ? .green : .orange)

                Divider()

                statusRow("Accessibility",
                          value: controller.accessibilityAuthorization.title,
                          systemImage: "cursorarrow.motionlines",
                          color: controller.accessibilityAuthorization == .granted ? .green : .orange)

                Divider()

                HStack(spacing: 12) {
                    Label("Display", systemImage: "display")
                    Spacer()
                    if controller.displays.isEmpty {
                        Text(controller.displayName)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Display", selection: $controller.selectedDisplayID) {
                            ForEach(controller.displays) { display in
                                Text(display.isMain ? "\(display.name) (Main)" : display.name)
                                    .tag(Optional(display.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        .disabled(controller.isStreaming || controller.isTransitioning)
                    }
                }
                .padding(.vertical, 10)

                Divider()

                statusRow("Connected Devices",
                          value: "\(controller.clientCount)",
                          systemImage: "iphone.gen3.radiowaves.left.and.right",
                          color: controller.clientCount > 0 ? .green : .secondary)

                Divider()

                if controller.screenRecordingAuthorization != .granted
                    || controller.accessibilityAuthorization != .granted {
                    VStack(spacing: 8) {
                        if controller.screenRecordingAuthorization != .granted {
                            permissionActionRow(
                                "Screen Recording",
                                allowAction: controller.requestScreenRecordingPermission,
                                settingsAction: controller.openScreenRecordingSettings
                            )
                        }

                        if controller.accessibilityAuthorization != .granted {
                            permissionActionRow(
                                "Accessibility for remote control",
                                allowAction: controller.requestAccessibilityPermission,
                                settingsAction: controller.openAccessibilitySettings
                            )
                        }
                    }
                    .padding(.top, 12)
                }

                Label {
                    Text(controller.captureStatusText)
                } icon: {
                    Image(systemName: controller.isStreaming
                          ? "record.circle.fill"
                          : "pause.circle")
                }
                .font(.callout)
                .foregroundStyle(controller.isStreaming ? .green : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)

                HStack(spacing: 12) {
                    if controller.isOnDemandStreaming {
                        Button("Keep Streaming") {
                            Task {
                                await controller.keepStreamingAfterDisconnect()
                            }
                        }
                        .help("Keep screen capture active after connected devices leave")
                    }

                    Spacer()

                    Button(controller.isStreaming
                           ? "Stop Streaming"
                           : "Start Streaming Continuously") {
                        Task {
                            await controller.toggleStreaming()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isStreaming ? .red : .accentColor)
                    .disabled(controller.runState == .starting || controller.isTransitioning)
                }
                .padding(.top, 12)

                Text("The host listener stays available without recording your screen. By default, capture starts only after an authenticated device connects and stops five seconds after the last device leaves. Starting continuously is an explicit always-on override.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)

                if let lastError = controller.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                }
            }
            .padding(4)
        }
    }

    private var pairingSection: some View {
        GroupBox("Pair a Glassy Desk Device") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter this rotating 12-symbol pairing code on the iPhone or iPad. Only devices that prove they know the code can receive encrypted screen frames.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Text(HostProtocol.pairingCodeDisplayValue(controller.pairingCode))
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Spacer(minLength: 12)

                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.pairingCode, forType: .string)
                    }

                    Button("Replace…") {
                        isResetConfirmationPresented = true
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))

                Text("Copy uses the 12 symbols without dashes. A new code appears in \(controller.pairingCodeRemainingSeconds) seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private var securityNote: some View {
        Label {
            Text("Glassy Host uses Bonjour for local discovery. Video and direct remote control are accepted only after an authenticated, encrypted handshake.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func statusRow(_ title: String,
                           value: String,
                           systemImage: String,
                           color: Color) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(color)
        }
        .padding(.vertical, 10)
    }

    private func permissionActionRow(_ title: String,
                                     allowAction: @escaping () -> Void,
                                     settingsAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Allow") {
                allowAction()
            }
            Button("Open Settings") {
                settingsAction()
            }
        }
    }
}

private struct StatusBadge: View {
    let state: HostRunState

    var body: some View {
        Label(state.title, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var systemImage: String {
        switch state {
        case .stopped:
            "stop.circle"
        case .starting:
            "hourglass"
        case .ready:
            "bolt.horizontal.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .stopped:
            .secondary
        case .starting:
            .orange
        case .ready:
            .green
        case .failed:
            .red
        }
    }
}
