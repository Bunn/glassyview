import SwiftUI

struct PairingPasswordEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: HostController
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.isPairingPasswordConfigured
                     ? "Change Pairing Password"
                     : "Set Pairing Password")
                    .font(.title2.weight(.semibold))
                Text("The rotating code remains the default and will continue to work.")
                    .foregroundStyle(.secondary)
            }

            Form {
                SecureField("Password", text: $password)
                SecureField("Confirm Password", text: $confirmation)
            }
            .formStyle(.grouped)

            Text("Use 15–128 characters. Spaces are allowed and significant. Glassy Desk enables password pairing only for recognizable Tailscale addresses on an active VPN route; use the rotating code for Nearby or other routes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let pairingPasswordError = controller.pairingPasswordError {
                Label(pairingPasswordError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    clearDrafts()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(controller.isPairingPasswordConfigured ? "Change" : "Set Password") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isSubmitting || controller.isUpdatingPairingPassword)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear(perform: clearDrafts)
    }

    private var normalizedPassword: String? {
        try? PairingPasswordPolicy.normalizedPassword(password)
    }

    private var normalizedConfirmation: String? {
        try? PairingPasswordPolicy.normalizedPassword(confirmation)
    }

    private var canSubmit: Bool {
        guard let normalizedPassword, let normalizedConfirmation else { return false }
        return normalizedPassword == normalizedConfirmation
    }

    private var validationMessage: String? {
        if !password.isEmpty {
            do {
                _ = try PairingPasswordPolicy.normalizedPassword(password)
            } catch {
                return error.localizedDescription
            }
        }
        if !confirmation.isEmpty {
            do {
                _ = try PairingPasswordPolicy.normalizedPassword(confirmation)
            } catch {
                return "Confirmation: \(error.localizedDescription)"
            }
        }
        if !confirmation.isEmpty,
           let normalizedPassword,
           let normalizedConfirmation,
           normalizedPassword != normalizedConfirmation {
            return "The passwords do not match."
        }
        return nil
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        Task { @MainActor in
            let didSave = await controller.setPairingPassword(password)
            isSubmitting = false
            if didSave {
                clearDrafts()
                dismiss()
            }
        }
    }

    private func clearDrafts() {
        password = ""
        confirmation = ""
    }
}
