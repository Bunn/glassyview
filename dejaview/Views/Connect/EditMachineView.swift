import SwiftUI
import OSLog

/// Sheet for creating or editing a saved machine.
struct EditMachineView<Store: MachineStoring>: View {
    @Environment(\.dismiss) private var dismiss
    let store: Store
    let glassyHostBrowser: GlassyHostBrowser
    let discoveredService: DiscoveredService?
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
    @State private var vncPortText: String
    @State private var glassyStreamPortText: String
    @State private var macAddress: String
    @State private var isRemoteConnectionInfoPresented = false

    private let isNew: Bool

    init(store: Store,
         machine: SavedMachine,
         password: String,
         glassyHostBrowser: GlassyHostBrowser,
         discoveredService: DiscoveredService? = nil,
         connectAfterDismiss: ((SavedMachine, String) -> Void)? = nil) {
        self.store = store
        self.glassyHostBrowser = glassyHostBrowser
        self.discoveredService = discoveredService
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
        let initialPort = machine.connectionMode == .glassyStream
            ? GlassyStreamEndpoint.effectivePort(for: machine)
            : machine.port
        _portText = State(initialValue: String(initialPort))
        _vncPortText = State(
            initialValue: machine.connectionMode == .vnc ? String(machine.port) : "5900"
        )
        _glassyStreamPortText = State(
            initialValue: machine.connectionMode == .glassyStream
                ? String(initialPort)
                : String(GlassyStreamEndpoint.defaultPort)
        )
        _macAddress = State(initialValue: machine.macAddress ?? "")
    }

    private var isGlassyHostDetected: Bool {
        guard let discoveredService else { return false }
        return BonjourMachineMatcher.glassyHost(
            matching: discoveredService,
            among: glassyHostBrowser.hosts
        ) != nil
    }

    private var glassyStreamDetectionMessage: String {
        switch connectionMode {
        case .vnc:
            "This Mac is advertising Glassy Stream support. Select Glassy Stream above to use it."
        case .glassyStream:
            "Glassy Stream is selected for this Mac. Save or connect to continue."
        }
    }

    private var glassyStreamDetectionHint: String {
        switch connectionMode {
        case .vnc:
            "Select Glassy Stream in the connection method picker to use it."
        case .glassyStream:
            "Save or connect to continue."
        }
    }

    private var canSubmit: Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIdentity = connectionMode == .vnc
            ? !trimmedHost.isEmpty
            : !trimmedName.isEmpty || !trimmedHost.isEmpty
        return hasIdentity && isPortValid && isGlassyAddressValid && isMACAddressValid
    }

    private var isPortValid: Bool {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return port > 0
    }

    private var isGlassyAddressValid: Bool {
        guard connectionMode == .glassyStream else { return true }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return true }
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0 else {
            return false
        }
        return GlassyStreamEndpoint.directAddress(
            from: trimmedHost,
            defaultPort: port
        ) != nil
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

                    if isGlassyHostDetected {
                        VStack(alignment: .leading, spacing: 4) {
                            GlassyStreamDetectionBadge(
                                title: "Glassy Stream detected on this Mac"
                            )

                            Text(glassyStreamDetectionMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(glassyStreamDetectionHint)
                        .accessibilityIdentifier("connection.glassy-host.detected")
                    }

                    Button {
                        isRemoteConnectionInfoPresented = true
                    } label: {
                        Label("Remote Connection Info", systemImage: "questionmark.circle")
                    }
                    .accessibilityHint("Explains how to securely connect to a Mac outside your local network.")
                    .accessibilityIdentifier("connection.remote-access-info")
                } header: {
                    Text("Connection")
                } footer: {
                    Text(connectionMode.description)
                }

                Section {
                    TextField(connectionMode == .vnc ? "Name (optional)" : "Name", text: $name)

                    TextField(
                        connectionMode == .vnc
                            ? "Host or IP address"
                            : "Host name or IP address (optional for nearby)",
                        text: $host
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel(
                            connectionMode == .vnc
                                ? "VNC host or IP address"
                                : "Glassy Stream host name or IP address"
                        )
                        .accessibilityIdentifier(
                            connectionMode == .vnc
                                ? "connection.vnc.address"
                                : "connection.glassy-stream.address"
                        )

                    TextField(
                        connectionMode == .vnc ? "Port" : "Glassy Host Port",
                        text: $portText
                    )
                        .keyboardType(.numberPad)

                    if !isPortValid {
                        Label("Enter a TCP port from 1 through 65535.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if !isGlassyAddressValid {
                        Label("Enter a host name, IPv4 address, or bracketed IPv6 address.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Machine")
                } footer: {
                    if connectionMode == .glassyStream {
                        Text("For remote access, use the Mac's Tailscale MagicDNS name or 100.x address. Connect both devices to the same tailnet; no public port forwarding is needed.")
                    } else {
                        Text("Enter the Mac's host name or IP address and its Screen Sharing port.")
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
                        Text("Changing this forgets the saved host identity. New pairing approval will be required on the next connection.")
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
            .onChange(of: connectionMode) { oldMode, newMode in
                updateDefaultPort(from: oldMode, to: newMode)
            }
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
            .sheet(isPresented: $isRemoteConnectionInfoPresented) {
                RemoteConnectionInfoSheet()
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
        let fallbackPort = connectionMode == .glassyStream
            ? GlassyStreamEndpoint.defaultPort
            : UInt16(5_900)
        prepared.port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? fallbackPort
        prepared.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.connectionMode = connectionMode
        prepared.glassyHostIdentifier = glassyHostIdentifier
        prepared.glassyHostName = glassyHostName

        if connectionMode == .glassyStream,
           let directAddress = GlassyStreamEndpoint.directAddress(
               from: prepared.host,
               defaultPort: prepared.port
           ) {
            prepared.host = directAddress.host
            prepared.port = directAddress.port
        }

        let trimmedMACAddress = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.macAddress = trimmedMACAddress.isEmpty
            ? nil
            : MACAddress(trimmedMACAddress)?.formatted

        if prepared.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prepared.name = prepared.host
        }

        return prepared
    }

    private func updateDefaultPort(
        from oldMode: RemoteConnectionMode,
        to newMode: RemoteConnectionMode
    ) {
        guard oldMode != newMode else { return }

        switch oldMode {
        case .vnc:
            vncPortText = portText
        case .glassyStream:
            glassyStreamPortText = portText
        }

        switch newMode {
        case .vnc:
            portText = vncPortText
        case .glassyStream:
            portText = glassyStreamPortText
        }
    }
}
