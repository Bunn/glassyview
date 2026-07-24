import SwiftUI
import OSLog

/// Sheet for creating or editing a saved machine.
struct EditMachineView<Store: MachineStoring>: View {
    @Environment(\.dismiss) private var dismiss
    let store: Store
    let connectAfterDismiss: ((SavedMachine, String) -> Void)?

    @State private var machine: SavedMachine
    @State private var name: String
    @State private var host: String
    @State private var username: String
    @State private var password: String
    @State private var portText: String
    @State private var macAddress: String

    private let isNew: Bool

    init(store: Store,
         machine: SavedMachine,
         password: String,
         connectAfterDismiss: ((SavedMachine, String) -> Void)? = nil) {
        self.store = store
        self.connectAfterDismiss = connectAfterDismiss
        isNew = !store.contains(machine)
        _machine = State(initialValue: machine)
        _name = State(initialValue: machine.name)
        _host = State(initialValue: machine.host)
        _username = State(initialValue: machine.username)
        _password = State(initialValue: password)
        _portText = State(initialValue: String(machine.port))
        _macAddress = State(initialValue: machine.macAddress ?? "")
    }

    private var canSubmit: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isMACAddressValid
    }

    private var isMACAddressValid: Bool {
        let value = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || MACAddress(value) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Machine") {
                    TextField("Name (optional)", text: $name)

                    TextField("Host or IP address", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                }

                Section("Login") {
                    CredentialTextField("Username (macOS login)", text: $username)

                    CredentialTextField("Password", text: $password, isSecure: true)
                }

                Section {
                    TextField("MAC Address (optional)", text: $macAddress)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .textContentType(.none)

                    if !isMACAddressValid {
                        Label("Enter six hexadecimal pairs, such as A1:B2:C3:D4:E5:F6.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Wake on LAN")
                } footer: {
                    Text("When this Mac is unreachable, Glassy Desk can wake it and connect automatically. Enable “Wake for network access” in macOS System Settings.")
                }

                if isNew, connectAfterDismiss != nil {
                    Section {
                        Button("Save and Connect", systemImage: "checkmark.circle") {
                            saveAndConnect()
                        }
                        .disabled(!canSubmit)

                        Button("Connect Without Saving", systemImage: "display") {
                            connectNow()
                        }
                        .disabled(!canSubmit)
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete Machine", role: .destructive) {
                            store.delete(machine)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Machine" : "Edit Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private func save() {
        let prepared = preparedMachine()
        AppLog.ui.info("Saving machine from editor; isNew=\(self.isNew, privacy: .public) host=\(prepared.host, privacy: .public):\(prepared.port, privacy: .public)")

        if isNew {
            store.add(prepared, password: password)
        } else {
            store.update(prepared, password: password)
        }

        dismiss()
    }

    private func connectNow() {
        let prepared = preparedMachine()
        AppLog.ui.info("Connecting without saving from editor to \(prepared.host, privacy: .public):\(prepared.port, privacy: .public)")
        connectAfterDismiss?(prepared, password)
        dismiss()
    }

    private func saveAndConnect() {
        let prepared = preparedMachine()
        AppLog.ui.info("Saving and connecting from editor; isNew=\(self.isNew, privacy: .public) host=\(prepared.host, privacy: .public):\(prepared.port, privacy: .public)")

        if isNew {
            store.add(prepared, password: password)
        } else {
            store.update(prepared, password: password)
        }

        connectAfterDismiss?(prepared, password)
        dismiss()
    }

    private func preparedMachine() -> SavedMachine {
        var prepared = machine
        prepared.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5900
        prepared.username = username.trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmedMACAddress = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.macAddress = trimmedMACAddress.isEmpty
            ? nil
            : MACAddress(trimmedMACAddress)?.formatted

        if prepared.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prepared.name = prepared.host
        }

        return prepared
    }
}
