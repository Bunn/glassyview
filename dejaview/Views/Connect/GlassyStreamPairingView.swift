import SwiftUI

@MainActor
struct GlassyStreamPairingView: View {
    @Environment(GlassyHostBrowser.self) private var hostBrowser
    @Environment(\.dismiss) private var dismiss

    let machine: SavedMachine
    let pairAndConnect: @MainActor (
        DiscoveredGlassyHost,
        GlassyHostPairingCode
    ) async throws -> Void

    @State private var selectedHostID: String?
    @State private var pairingCodeText = ""
    @State private var isPairing = false
    @State private var errorMessage: String?

    init(
        machine: SavedMachine,
        initialErrorMessage: String? = nil,
        pairAndConnect: @escaping @MainActor (
            DiscoveredGlassyHost,
            GlassyHostPairingCode
        ) async throws -> Void
    ) {
        self.machine = machine
        self.pairAndConnect = pairAndConnect
        _errorMessage = State(initialValue: initialErrorMessage)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Glassy Host") {
                    if hostBrowser.hosts.isEmpty {
                        ContentUnavailableView(
                            "No Glassy Host Found",
                            systemImage: "macbook.slash",
                            description: Text(
                                "Open Glassy Host on the Mac and keep both devices on the same local network. Streaming starts automatically after authentication."
                            )
                        )
                    } else {
                        Picker("Mac", selection: $selectedHostID) {
                            ForEach(hostBrowser.hosts) { host in
                                Text(host.name)
                                    .tag(Optional(host.id))
                            }
                        }
                    }
                }

                Section {
                    TextField("12-symbol code", text: $pairingCodeText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .textContentType(.oneTimeCode)

                    if !pairingCodeText.isEmpty, pairingCode == nil {
                        Label(
                            "Enter the 12 symbols shown by Glassy Host. Dashes are optional.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.red)
                    }
                } header: {
                    Text("Pairing Code")
                } footer: {
                    Text("Enter the code displayed by Glassy Host on your Mac. The code changes every minute and is used only for first-time pairing.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Pair Glassy Stream")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isPairing)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair & Connect") {
                        pair()
                    }
                    .disabled(selectedHost == nil || pairingCode == nil || isPairing)
                }
            }
            .interactiveDismissDisabled(isPairing)
            .onChange(of: hostBrowser.hosts.map(\.id), initial: true) { _, hostIDs in
                if !hostIDs.contains(selectedHostID ?? "") {
                    selectedHostID = hostIDs.first
                }
            }
        }
    }

    private var selectedHost: DiscoveredGlassyHost? {
        guard let selectedHostID else { return nil }
        return hostBrowser.hosts.first { $0.id == selectedHostID }
    }

    private var pairingCode: GlassyHostPairingCode? {
        GlassyHostPairingCode(pairingCodeText)
    }

    private func pair() {
        guard let selectedHost, let pairingCode else { return }

        errorMessage = nil
        isPairing = true
        Task { @MainActor in
            defer { isPairing = false }

            do {
                try await pairAndConnect(selectedHost, pairingCode)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
