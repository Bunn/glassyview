import SwiftUI

@MainActor
struct GlassyStreamPairingView: View {
    private enum PairingMethod {
        case oneTimeCode
        case password
    }

    @Environment(GlassyHostBrowser.self) private var hostBrowser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let machine: SavedMachine
    let fixedCandidate: GlassyStreamEndpointCandidate?
    let restrictsScannedEndpoint: Bool
    let isEmbedded: Bool
    let onPaired: (() -> Void)?
    let onClose: (() -> Void)?
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
    @State private var hasConnected = false
    @State private var showsConnectionOptions = false
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
        isEmbedded: Bool = false,
        onPaired: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        pairAndConnect: @escaping @MainActor (
            GlassyStreamEndpointCandidate,
            GlassyStreamBootstrapCredential
        ) async throws -> Void
    ) {
        self.machine = machine
        self.fixedCandidate = fixedCandidate
        self.restrictsScannedEndpoint = restrictsScannedEndpoint
        self.isEmbedded = isEmbedded
        self.onPaired = onPaired
        self.onClose = onClose
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
        Group {
            if isEmbedded {
                pairingContent
            } else {
                NavigationStack { pairingContent }
            }
        }
        .presentationDetents([.large])
    }

    private var pairingContent: some View {
        // Keep the task owner mounted while scan, form, and success content transition.
        ZStack {
            if hasConnected {
                VStack(spacing: 12) {
                    MacPairingIllustration(isRecognized: true)
                    Text("You’re connected.")
                        .font(.largeTitle.bold())
                    Text("Your Mac is coming right up.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else if isShowingQRScanner {
                scannerContent
                    .transition(stepTransition)
            } else {
                Form { manualPairingContent }
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom, spacing: 0) { manualConnectButton }
                    .transition(stepTransition)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(isShowingQRScanner ? "Scan Mac’s Code" : "Pair Your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isPairing)
        .toolbar {
            if !isEmbedded || onClose != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        clearBootstrapInputs()
                        if let onClose { onClose() } else { dismiss() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(isPairing)
                }
            }
            if !isEmbedded && !isShowingQRScanner {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Scan Code", systemImage: "qrcode.viewfinder", action: beginScanning)
                        .labelStyle(.iconOnly)
                        .disabled(isPairing)
                }
            }
        }
        .interactiveDismissDisabled(isPairing)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.88), value: isShowingQRScanner)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: scannedInvitation != nil)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: hasConnected)
        .sensoryFeedback(.success, trigger: scannedInvitation != nil)
        .sensoryFeedback(.success, trigger: hasConnected)
        .onChange(of: candidates.map(\.id), initial: true) { _, candidateIDs in
            guard !candidateIDs.contains(selectedCandidateID ?? "") else { return }
            // Only an address entered by the user may be selected automatically.
            selectedCandidateID = candidates.first(where: { $0.source == .direct })?.id
        }
        .onChange(of: pairingMethod) { oldMethod, _ in
            switch oldMethod {
            case .oneTimeCode: pairingCodeText = ""
            case .password: pairingPasswordText = ""
            }
            errorMessage = nil
        }
        .task(id: isPairing) {
            guard isPairing else { return }
            await performPairing()
        }
        .onDisappear { clearBootstrapInputs() }
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12))
    }

    @ViewBuilder
    private var manualPairingContent: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "lock.desktopcomputer")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(fixedCandidate == nil ? "A few details. Then you’re in." : "One last step.")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(pairingMethod == .oneTimeCode
                     ? "On your Mac, open Glassy Desk → Add Device → Enter Code."
                     : "Use the pairing password you set in Glassy Desk on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
        }

        if let fixedCandidate {
            Section("Your Mac") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fixedCandidate.name).font(.headline)
                        Text(fixedCandidate.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "desktopcomputer").foregroundStyle(.tint)
                }
                .padding(.vertical, 6)
            }
        } else {
            Section {
                TextField("Host name or IP address", text: $directAddressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(isPairing)
                    .accessibilityLabel("Mac address")
                    .accessibilityIdentifier("connection.glassy-stream.address")

                if let directInputValidationMessage {
                    credentialValidationLabel(directInputValidationMessage)
                }
            } header: {
                Text("Mac Address")
            } footer: {
                Text("Use your Mac’s local address or an address reachable through your VPN.")
            }


        }

        Section {
            switch pairingMethod {
            case .oneTimeCode:
                TextField("12-symbol code", text: $pairingCodeText)
                    .font(.title3.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .textContentType(.oneTimeCode)
                    .privacySensitive()
                    .disabled(isPairing)
                    .accessibilityIdentifier("connection.glassy-stream.code")

                if pairingCodeText.filter({ $0.isLetter || $0.isNumber }).count >= 12,
                   pairingCode == nil {
                    credentialValidationLabel("Check the 12 symbols shown on your Mac. Dashes are optional.")
                }
            case .password:
                SecureField("Pairing password", text: $pairingPasswordText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .privacySensitive()
                    .disabled(isPairing || !isPasswordPairingRouteAllowed)
                    .accessibilityIdentifier("connection.glassy-stream.password")

                if let passwordPairingRouteMessage {
                    credentialValidationLabel(passwordPairingRouteMessage)
                } else if !pairingPasswordText.isEmpty, let passwordValidationMessage {
                    credentialValidationLabel(passwordValidationMessage)
                }
            }
        } header: {
            Text(pairingMethod == .oneTimeCode ? "Code on Your Mac" : "Pairing Password")
        } footer: {
            if pairingMethod == .oneTimeCode {
                Text("The code refreshes every minute. You only need to pair once.")
            } else {
                Text("Use the password set in Glassy Desk. Keep Tailscale connected and confirm this address belongs to your Mac.")
                if let selectedCandidate, let selectedManualCandidate,
                   selectedCandidate.endpoint != selectedManualCandidate.endpoint {
                    Text("Connecting through \(selectedCandidate.detail).")
                }
            }
        }

        if pairingMethod == .password || selectedManualCandidate?.passwordPairingCandidate != nil {
            Section {
                Button(pairingMethod == .oneTimeCode ? "Use a pairing password" : "Use a one-time code") {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                        pairingMethod = pairingMethod == .oneTimeCode ? .password : .oneTimeCode
                    }
                }
                .font(.subheadline)
                .disabled(isPairing)
            }
        }

        if fixedCandidate == nil {
            Section {
                DisclosureGroup("Connection options", isExpanded: $showsConnectionOptions) {
                    LabeledContent("Port") {
                        TextField("51515", text: $directPortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Connection port")
                    }
                    .disabled(isPairing)
                }
            }
        }

        if let errorMessage {
            Section { credentialValidationLabel(errorMessage) }
        }
    }

    private var manualConnectButton: some View {
        Button(action: pair) {
            HStack(spacing: 10) {
                if isPairing { ProgressView().tint(.white) }
                Text(isPairing ? "Connecting…" : "Pair & Connect")
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glassProminent)
        .disabled(selectedCandidate == nil || bootstrapCredential == nil || isPairing)
        .accessibilityIdentifier("connection.glassy-stream.confirm")
        .frame(maxWidth: 460)
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var scannerContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let invitation = scannedInvitation {
                    GlassyPairingReviewView(invitation: invitation, isPairing: isPairing, pair: pair)
                        .transition(stepTransition)

                    Button("Scan a different code", action: beginScanning)
                        .font(.subheadline)
                        .frame(minHeight: 44)
                        .disabled(isPairing)
                } else {
                    VStack(spacing: 10) {
                        Text("Point. Scan. Almost there.")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text("In Glassy Desk on your Mac, choose Add Device and point your camera at the code.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    if let scanErrorMessage {
                        ContentUnavailableView("Let’s try that again", systemImage: "qrcode.viewfinder",
                                               description: Text(scanErrorMessage))
                        Button("Scan Again", action: beginScanning)
                            .buttonStyle(.glassProminent)
                    } else {
                        GlassyPairingScannerView(onScan: receiveScan)
                            .id(scannerID)
                            .frame(minHeight: 300)
                            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))
                    }

                    Label("You’ll confirm your Mac before connecting.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Enter a code instead") {
                        clearBootstrapInputs()
                        isShowingQRScanner = false
                        errorMessage = nil
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("connection.glassy-stream.manual")
                }

                if let errorMessage {
                    credentialValidationLabel(errorMessage)
                }
            }
            .frame(maxWidth: 460)
            .padding(24)
            .frame(maxWidth: .infinity)
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
                scanErrorMessage = String(localized: "This QR code belongs to a different Mac. Close this setup and choose Add Mac to add it separately.")
                return
            }
            if restrictsScannedEndpoint,
               pinnedIdentifier?.count != GlassyStreamWire.identifierLength,
               let savedAddress = GlassyStreamEndpoint.directAddress(
                   from: machine.host,
                   defaultPort: GlassyStreamEndpoint.effectivePort(for: machine)
               ), !invitation.matchesAddress(savedAddress) {
                scanErrorMessage = String(localized: "This QR code uses a different Mac address. To add it without changing your saved Mac, close this setup and choose Add Mac.")
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
            return String(localized: "Enter a valid host name or IP address.")
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
        return String(localized: "Pairing passwords need a Tailscale IP address or full .ts.net name. Use a one-time code for other networks.")
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
        guard !isPairing else { return }
        if isShowingQRScanner, let scannedInvitation, scannedInvitation.expiresAt <= .now {
            errorMessage = GlassyHostPairingInvitation.ValidationError.expired.localizedDescription
            return
        }
        guard selectedCandidate != nil, bootstrapCredential != nil else { return }
        errorMessage = nil
        isPairing = true
    }

    private func performPairing() async {
        defer { isPairing = false }
        guard let selectedCandidate, let bootstrapCredential else { return }
        do {
            try await pairAndConnect(selectedCandidate, bootstrapCredential)
            try Task.checkCancellation()
            hasConnected = true
            if !reduceMotion {
                try await Task.sleep(for: .milliseconds(450))
            }
            try Task.checkCancellation()
            clearBootstrapInputs()
            if let onPaired { onPaired() } else { dismiss() }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = pairingFailureMessage(error)
        }
    }

    private func pairingFailureMessage(_ error: Error) -> String {
        if pairingMethod == .password,
           let sessionError = error as? GlassyStreamSessionError,
           case .transport(.authenticationRejected) = sessionError {
            return String(localized: "Glassy Desk did not accept that pairing password. Check the password configured on the Mac and try again.")
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

#Preview("Pair with a code") {
    GlassyStreamPairingView(
        machine: SavedMachine(name: "", host: "", port: GlassyStreamEndpoint.defaultPort,
                              username: "", connectionMode: .glassyStream),
        pairAndConnect: { _, _ in }
    )
    .environment(GlassyHostBrowser())
}
