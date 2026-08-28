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
    @State private var connectionMode: RemoteConnectionMode
    @State private var glassyHostIdentifier: String?
    @State private var glassyHostName: String?
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
        _connectionMode = State(initialValue: machine.connectionMode)
        _glassyHostIdentifier = State(initialValue: machine.glassyHostIdentifier)
        _glassyHostName = State(initialValue: machine.glassyHostName)
        _portText = State(initialValue: String(machine.port))
        _macAddress = State(initialValue: machine.macAddress ?? "")
    }

    private var canSubmit: Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIdentity = connectionMode == .vnc
            ? !trimmedHost.isEmpty
            : !trimmedName.isEmpty || !trimmedHost.isEmpty
        return hasIdentity && isMACAddressValid
    }

    private var isMACAddressValid: Bool {
        let value = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || MACAddress(value) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Connection Method", selection: $connectionMode) {
                        ForEach(RemoteConnectionMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Choose standard VNC or the faster Glassy Host stream for this Mac.")
                } header: {
                    Text("Connection")
                } footer: {
                    Text(connectionMode.description)
                }

                Section("Machine") {
                    TextField(connectionMode == .vnc ? "Name (optional)" : "Name", text: $name)

                    TextField(
                        connectionMode == .vnc
                            ? "Host or IP address"
                            : "Mac name or IP address (optional)",
                        text: $host
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if connectionMode == .vnc {
                        TextField("Port", text: $portText)
                            .keyboardType(.numberPad)
                    }
                }

                if connectionMode == .vnc {
                    Section {
                        CredentialTextField("Username (macOS login)", text: $username)

                        CredentialTextField("Password", text: $password, isSecure: true)
                    } header: {
                        Text("VNC Credentials")
                    } footer: {
                        Text("Use a macOS account allowed to share the screen. Legacy VNC servers may only require a password.")
                    }
                }

                if connectionMode == .glassyStream, let glassyHostIdentifier {
                    Section {
                        LabeledContent("Paired Mac") {
                            Text(glassyHostName ?? "Glassy Host")
                                .foregroundStyle(.secondary)
                        }

                        Button("Pair a Different Mac", role: .destructive) {
                            self.glassyHostIdentifier = nil
                            glassyHostName = nil
                        }
                    } footer: {
                        Text("Changing this forgets the saved host identity. A new pairing code will be required on the next connection.")
                    }
                    .id(glassyHostIdentifier)
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
        prepared.connectionMode = connectionMode
        prepared.glassyHostIdentifier = glassyHostIdentifier
        prepared.glassyHostName = glassyHostName

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
