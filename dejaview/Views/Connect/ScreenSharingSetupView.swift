import SwiftUI

/// The standard VNC path has one form and one completion action.
struct ScreenSharingSetupView<Store: MachineStoring>: View {
    let store: Store
    let machine: SavedMachine
    let connect: (SavedMachine, String) -> Void
    @State private var host: String
    @State private var name: String
    @State private var username = ""
    @State private var password = ""
    @State private var portText: String
    @State private var showsOptions = false

    init(store: Store, machine: SavedMachine,
         connect: @escaping (SavedMachine, String) -> Void) {
        self.store = store
        self.machine = machine
        self.connect = connect
        _host = State(initialValue: machine.host)
        _name = State(initialValue: machine.name)
        _portText = State(initialValue: String(machine.connectionMode == .vnc ? machine.port : 5_900))
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Connect with your Mac login.")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("On your Mac, turn on Screen Sharing in System Settings → General → Sharing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            }

            Section("Mac Address") {
                TextField("Host name or IP address", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("connection.vnc.address")
            }

            Section {
                CredentialTextField("Username", text: $username)
                    .accessibilityLabel("Mac username")
                CredentialTextField("Password", text: $password, isSecure: true)
                    .accessibilityLabel("Mac password")
                    .privacySensitive()
            } header: {
                Text("Mac Login")
            } footer: {
                Text("Use an account allowed to share this Mac’s screen. A VNC password may not need a username.")
            }

            Section {
                DisclosureGroup("Options", isExpanded: $showsOptions) {
                    TextField("Name (optional)", text: $name)
                    LabeledContent("Port") {
                        TextField("5900", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Screen Sharing port")
                    }
                    if port == nil {
                        Text("Enter a port from 1 to 65535.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button(action: addAndConnect) {
                Text("Add & Connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || port == nil)
            .accessibilityIdentifier("connection.vnc.add-connect")
            .frame(maxWidth: 460)
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
        }
        .navigationTitle("Standard VNC")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var port: UInt16? {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return nil
        }
        return value
    }

    private func addAndConnect() {
        guard let port else { return }
        var prepared = machine
        prepared.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prepared.host.isEmpty else { return }
        prepared.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if prepared.name.isEmpty { prepared.name = prepared.host }
        prepared.port = port
        prepared.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.connectionMode = .vnc
        store.add(prepared, password: password)
        connect(prepared, password)
    }
}
