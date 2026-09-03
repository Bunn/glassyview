import SwiftUI

@MainActor
struct GlassyStreamPairingView: View {
    private enum PairingMethod: String, CaseIterable, Identifiable {
        case oneTimeCode
        case password

        var id: Self { self }

        var title: String {
            switch self {
            case .oneTimeCode:
                String(localized: "One-Time Code")
            case .password:
                String(localized: "Password")
            }
        }
    }

    @Environment(GlassyHostBrowser.self) private var hostBrowser
    @Environment(\.dismiss) private var dismiss

    let machine: SavedMachine
    let fixedCandidate: GlassyStreamEndpointCandidate?
    let restrictsScannedEndpoint: Bool
    let pairAndConnect: @MainActor (
        GlassyStreamEndpointCandidate,
        GlassyStreamBootstrapCredential
    ) async throws -> Void

    @State private var selectedCandidateID: String?
    @State private var directAddressText: String
    @State private var directPortText: String
    @State private var pairingMethod: PairingMethod = .oneTimeCode
    @State private var pairingCodeText = ""
    @State private var pairingPasswordText = ""
    @State private var isPairing = false
    @State private var isShowingQRScanner: Bool
    @State private var scannedInvitation: GlassyHostPairingInvitation?
    @State private var scanErrorMessage: String?
    @State private var scannerID = UUID()
    @State private var errorMessage: String?

    init(
        machine: SavedMachine,
        initialErrorMessage: String? = nil,
        fixedCandidate: GlassyStreamEndpointCandidate? = nil,
        startsWithScanner: Bool = false,
        restrictsScannedEndpoint: Bool = false,
        pairAndConnect: @escaping @MainActor (
            GlassyStreamEndpointCandidate,
            GlassyStreamBootstrapCredential
        ) async throws -> Void
    ) {
        self.machine = machine
        self.fixedCandidate = fixedCandidate
        self.restrictsScannedEndpoint = restrictsScannedEndpoint
        self.pairAndConnect = pairAndConnect
        _isShowingQRScanner = State(initialValue: startsWithScanner)
        _errorMessage = State(initialValue: initialErrorMessage)
        _selectedCandidateID = State(initialValue: fixedCandidate?.id)

        let effectivePort = GlassyStreamEndpoint.effectivePort(for: machine)
        if let directAddress = GlassyStreamEndpoint.directAddress(
            from: machine.host,
            defaultPort: effectivePort
        ) {
            _directAddressText = State(initialValue: directAddress.host)
            _directPortText = State(initialValue: String(directAddress.port))
        } else {
            _directAddressText = State(
                initialValue: machine.host.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            _directPortText = State(initialValue: String(effectivePort))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isShowingQRScanner {
                    qrPairingContent
                } else {
                    Section {
                        Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
                            beginScanning()
                        }
                        .disabled(isPairing)
                        .accessibilityIdentifier("connection.glassy-stream.scan")
                    } footer: {
                        Text("Scan the QR code on your Mac to fill in its address and pairing code.")
                    }

                    manualPairingContent
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
                        clearBootstrapInputs()
                        dismiss()
                    }
                    .disabled(isPairing)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if !isShowingQRScanner {
                        Button("Pair & Connect") {
                            pair()
                        }
                        .disabled(selectedCandidate == nil || bootstrapCredential == nil || isPairing)
                    }
                }
            }
            .interactiveDismissDisabled(isPairing)
            .onChange(of: candidates.map(\.id), initial: true) { _, candidateIDs in
                guard !candidateIDs.contains(selectedCandidateID ?? "") else { return }

                // A saved direct address is explicit user intent and is safe to
                // preselect. Nearby results require a deliberate choice so a
                // code can never be sent to an arbitrary first Bonjour result.
                selectedCandidateID = candidates.first(where: { $0.source == .direct })?.id
            }
            .onChange(of: pairingMethod) { oldMethod, _ in
                switch oldMethod {
                case .oneTimeCode:
                    pairingCodeText = ""
                case .password:
                    pairingPasswordText = ""
                }
                errorMessage = nil
            }
            .onDisappear {
                clearBootstrapInputs()
            }
        }
    }

    @ViewBuilder
    private var manualPairingContent: some View {
        if fixedCandidate == nil {
            Section {
                TextField("Host name or IP address", text: $directAddressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(isPairing)
                    .accessibilityLabel("Glassy Stream host name or IP address")
                    .accessibilityIdentifier("connection.glassy-stream.address")

                TextField("TCP port", text: $directPortText)
                    .keyboardType(.numberPad)
                    .disabled(isPairing)

                if let directInputValidationMessage {
                    Label(
                        directInputValidationMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.red)
                }
            } header: {
                Text("Connection Address")
            } footer: {
                if directAddressText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    Text("Enter the remote Mac's Tailscale MagicDNS name or 100.x address. Leave the address empty to choose a nearby Mac instead.")
                } else {
                    Text("Glassy Host uses TCP port \(GlassyStreamEndpoint.defaultPort) by default. A port included in the address takes precedence.")
                }
            }
        }

        Section {
            if candidates.isEmpty {
                ContentUnavailableView(
                    directInputValidationMessage == nil
                        ? "No Connection Route"
                        : "Fix the Connection Address",
                    systemImage: directInputValidationMessage == nil
                        ? "macbook.slash"
                        : "exclamationmark.triangle",
                    description: Text(
                        directInputValidationMessage == nil
                            ? "Open Glassy Host on the Mac. For remote access, enter its Tailscale name or 100.x address. For nearby access, keep both devices on the same local network."
                            : "Correct the address or TCP port before selecting a Mac."
                    )
                )
            } else {
                Picker("Mac", selection: $selectedCandidateID) {
                    Text("Choose a Mac")
                        .tag(String?.none)

                    ForEach(candidates) { candidate in
                        Text("\(candidate.name) — \(candidate.detail)")
                            .tag(Optional(candidate.id))
                    }
                }
            }
        } header: {
            Text("Glassy Host")
        } footer: {
            if candidates.contains(where: { $0.source == .direct }) {
                Text("Direct uses the saved Tailscale or network address. Nearby Macs are discovered only on the local network.")
            } else {
                Text("Choose the Mac displaying the pairing code. Nearby discovery works only on the local network.")
            }
        }

        Section {
            Picker("Pair Using", selection: $pairingMethod) {
                ForEach(PairingMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isPairing)

            switch pairingMethod {
            case .oneTimeCode:
                TextField("12-symbol code", text: $pairingCodeText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .textContentType(.oneTimeCode)
                    .disabled(isPairing)

                if !pairingCodeText.isEmpty, pairingCode == nil {
                    credentialValidationLabel(
                        "Enter the 12 symbols shown by Glassy Host. Dashes are optional."
                    )
                }

            case .password:
                SecureField("Pairing password", text: $pairingPasswordText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .privacySensitive()
                    .disabled(isPairing || !isPasswordPairingRouteAllowed)

                if let passwordPairingRouteMessage {
                    credentialValidationLabel(passwordPairingRouteMessage)
                } else if !pairingPasswordText.isEmpty,
                   let passwordValidationMessage {
                    credentialValidationLabel(passwordValidationMessage)
                }
            }
        } header: {
            Text("Authentication")
        } footer: {
            switch pairingMethod {
            case .oneTimeCode:
                Text("Enter the code displayed by Glassy Host. It changes every minute and remains the recommended default for first-time pairing.")
            case .password:
                if let selectedCandidate, let selectedManualCandidate,
                   selectedCandidate.endpoint != selectedManualCandidate.endpoint {
                    Text("Using \(selectedCandidate.detail) for password pairing over Tailscale.")
                }
                Text("Before pairing, confirm Tailscale is connected and the selected peer is your Mac. Glassy Desk also requires a Tailscale IP or full .ts.net name and an active VPN route. Later connections use a random Keychain credential.")
            }
        }
    }

    @ViewBuilder
    private var qrPairingContent: some View {
        if let invitation = scannedInvitation {
            Section {
                GlassyPairingReviewView(
                    invitation: invitation,
                    isPairing: isPairing,
                    pair: pair
                )
                if invitation.addresses.count > 1 {
                    Label("Glassy Desk will find an available Wi-Fi or VPN connection to this Mac.",
                          systemImage: "network")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Scan Again", systemImage: "qrcode.viewfinder", action: beginScanning)
                    .disabled(isPairing)
            }
        } else {
            Section {
                if let scanErrorMessage {
                    ContentUnavailableView(
                        "Try Scanning Again",
                        systemImage: "qrcode.viewfinder",
                        description: Text(scanErrorMessage)
                    )
                    Button("Scan Again", action: beginScanning)
                } else {
                    GlassyPairingScannerView(onScan: receiveScan)
                        .id(scannerID)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            } header: {
                Text("Scan Your Mac’s QR Code")
            } footer: {
                Text("In Glassy Host on your Mac, choose Add Device, then point the camera at the QR code. Connect through the same Wi-Fi network or a VPN such as Tailscale. You’ll review the Mac before connecting.")
            }
        }

        Section {
            Button("Enter Code Manually", systemImage: "keyboard") {
                clearBootstrapInputs()
                isShowingQRScanner = false
                errorMessage = nil
            }
            .disabled(isPairing)
        }
    }

    private func beginScanning() {
        clearBootstrapInputs()
        pairingMethod = .oneTimeCode
        scanErrorMessage = nil
        errorMessage = nil
        scannerID = UUID()
        isShowingQRScanner = true
    }

    private func receiveScan(_ value: String) {
        do {
            let invitation = try GlassyHostPairingInvitation(scannedValue: value)
            let pinnedIdentifier = machine.glassyHostIdentifier.flatMap { Data(base64Encoded: $0) }
            if let pinnedIdentifier, pinnedIdentifier.count == GlassyStreamWire.identifierLength,
               let scannedIdentifier = invitation.expectedHostIdentifier,
               pinnedIdentifier != scannedIdentifier {
                scanErrorMessage = String(localized: "This QR code belongs to a different Mac. Return to Connect and choose Scan QR Code to add it separately.")
                return
            }
            if restrictsScannedEndpoint,
               pinnedIdentifier?.count != GlassyStreamWire.identifierLength,
               let savedAddress = GlassyStreamEndpoint.directAddress(
                   from: machine.host,
                   defaultPort: GlassyStreamEndpoint.effectivePort(for: machine)
               ), !invitation.matchesAddress(savedAddress) {
                scanErrorMessage = String(localized: "This QR code uses a different Mac address. To add it without changing your saved Mac, return to Connect and choose Scan QR Code.")
                return
            }
            scannedInvitation = invitation
            scanErrorMessage = nil
        } catch {
            scanErrorMessage = error.localizedDescription
        }
    }

    private var candidates: [GlassyStreamEndpointCandidate] {
        if let fixedCandidate {
            return [fixedCandidate]
        }

        guard directInputValidationMessage == nil else { return [] }

        return GlassyStreamEndpoint.candidates(
            for: pairingMachine,
            discoveredHosts: hostBrowser.hosts
        )
    }

    private var pairingMachine: SavedMachine {
        var pairingMachine = machine
        pairingMachine.connectionMode = .glassyStream
        pairingMachine.host = directAddressText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        pairingMachine.port = directPort ?? GlassyStreamEndpoint.defaultPort
        return pairingMachine
    }

    private var directPort: UInt16? {
        let value = directPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              let port = UInt16(value),
              port > 0 else {
            return nil
        }
        return port
    }

    private var directInputValidationMessage: String? {
        guard fixedCandidate == nil else { return nil }

        let address = directAddressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }

        guard let directPort else {
            return String(localized: "Enter a TCP port from 1 to 65535.")
        }

        guard GlassyStreamEndpoint.directAddress(
            from: address,
            defaultPort: directPort
        ) != nil else {
            return String(localized: "Enter a valid Tailscale name or IP address.")
        }

        return nil
    }

    private var selectedCandidate: GlassyStreamEndpointCandidate? {
        if isShowingQRScanner { return scannedInvitation?.candidate }
        guard let selectedManualCandidate else { return nil }
        return pairingMethod == .password
            ? selectedManualCandidate.passwordPairingCandidate
            : selectedManualCandidate
    }

    private var selectedManualCandidate: GlassyStreamEndpointCandidate? {
        guard let selectedCandidateID else { return nil }
        return candidates.first { $0.id == selectedCandidateID }
    }

    private var pairingCode: GlassyHostPairingCode? {
        GlassyHostPairingCode(pairingCodeText)
    }

    private var passwordValidationMessage: String? {
        GlassyStreamPairingPassword.validationFailure(
            for: pairingPasswordText
        )?.message
    }

    private var isPasswordPairingRouteAllowed: Bool {
        guard let selectedCandidate else { return false }
        return GlassyStreamEndpoint.isRecognizedTailscaleEndpoint(
            selectedCandidate.endpoint
        )
    }

    private var passwordPairingRouteMessage: String? {
        guard pairingMethod == .password,
              !isPasswordPairingRouteAllowed else { return nil }
        return String(localized: "Choose a saved Tailscale 100.64–100.127 address, Tailscale IPv6 address, or full .ts.net name. Use the one-time code for Nearby or other routes.")
    }

    private var bootstrapCredential: GlassyStreamBootstrapCredential? {
        if isShowingQRScanner {
            guard let scannedInvitation, scannedInvitation.expiresAt > .now else { return nil }
            return .oneTimeCode(scannedInvitation.code.rawValue)
        }
        switch pairingMethod {
        case .oneTimeCode:
            guard let pairingCode else { return nil }
            return .oneTimeCode(pairingCode.rawValue)
        case .password:
            guard isPasswordPairingRouteAllowed else { return nil }
            guard let password = GlassyStreamPairingPassword.validated(
                pairingPasswordText
            ) else {
                return nil
            }
            return .password(password)
        }
    }

    private func pair() {
        if isShowingQRScanner, let scannedInvitation, scannedInvitation.expiresAt <= .now {
            errorMessage = GlassyHostPairingInvitation.ValidationError.expired.localizedDescription
            return
        }
        guard let selectedCandidate, let bootstrapCredential else { return }

        errorMessage = nil
        isPairing = true
        Task { @MainActor in
            defer { isPairing = false }

            do {
                try await pairAndConnect(selectedCandidate, bootstrapCredential)
                clearBootstrapInputs()
                dismiss()
            } catch {
                errorMessage = pairingFailureMessage(error)
            }
        }
    }

    private func pairingFailureMessage(_ error: Error) -> String {
        if pairingMethod == .password,
           let sessionError = error as? GlassyStreamSessionError,
           case .transport(.authenticationRejected) = sessionError {
            return String(localized: "Glassy Host did not accept that pairing password. Check the password configured on the Mac and try again.")
        }

        let description = error.localizedDescription
        guard let localizedError = error as? LocalizedError,
              let suggestion = localizedError.recoverySuggestion,
              !suggestion.isEmpty else {
            return description
        }
        return "\(description) \(suggestion)"
    }

    private func credentialValidationLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
    }

    private func clearBootstrapInputs() {
        pairingCodeText = ""
        pairingPasswordText = ""
        scannedInvitation = nil
    }
}
