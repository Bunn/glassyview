import SwiftUI

/// One entry point for a new Mac. Connection details appear only after choosing a path.
@MainActor
struct AddMachineView<Store: MachineStoring>: View {
    private enum Route: Hashable {
        case glassyStream, manualOptions, scanner, manual, nearby(NearbySelection), screenSharing
    }

    private struct NearbySelection: Hashable {
        let candidate: GlassyStreamEndpointCandidate

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.candidate.id == rhs.candidate.id }
        func hash(into hasher: inout Hasher) { hasher.combine(candidate.id) }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(GlassyHostBrowser.self) private var hostBrowser
    let store: Store
    let machine: SavedMachine
    let initialCandidate: GlassyStreamEndpointCandidate?
    let startsWithScreenSharing: Bool
    let pairAndConnect: @MainActor (GlassyStreamEndpointCandidate, GlassyStreamBootstrapCredential) async throws -> Void
    let connectScreenSharing: (SavedMachine, String) -> Void

    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if startsWithScreenSharing || !FeatureFlags.isGlassyStreamEnabled {
                    screenSharing(showsCloseButton: true)
                } else if let initialCandidate {
                    pairing(candidate: initialCandidate, showsCloseButton: true)
                } else {
                    welcome
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .glassyStream:
                    GlassyStreamSetupView(
                        scan: { path.append(.scanner) },
                        pairManually: { path.append(.manualOptions) }
                    )
                case .manualOptions:
                    manualOptions
                case .scanner:
                    pairing(startsWithScanner: true)
                case .manual:
                    pairing()
                case .nearby(let selection):
                    pairing(candidate: selection.candidate)
                case .screenSharing:
                    screenSharing()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var welcome: some View {
        AddMachineWelcomeView(
            useGlassyStream: { path.append(.glassyStream) },
            useVNC: { path.append(.screenSharing) }
        )
        .toolbar { closeButton }
    }

    private var manualOptions: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect without a camera.")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose a nearby Mac or enter its address, then pair with Glassy Desk.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            }

            Section("Nearby Macs") {
                if nearbyCandidates.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No nearby Macs yet")
                                .foregroundStyle(.primary)
                            Text("Open Glassy Desk on your Mac and join the same Wi-Fi network.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wifi")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(nearbyCandidates) { candidate in
                        Button {
                            path.append(.nearby(NearbySelection(candidate: candidate)))
                        } label: {
                            optionRow(title: candidate.name, detail: "Enter the code shown on this Mac",
                                      symbol: "desktopcomputer")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("connection.add-mac.nearby.\(candidate.id)")
                    }
                }
            }

            Section {
                NavigationLink(value: Route.manual) {
                    optionRow(title: String(localized: "Enter an address"), detail: "Connect with a Glassy Desk code or password",
                              symbol: "keyboard", showsChevron: false)
                }
                .accessibilityIdentifier("connection.add-mac.manual")
            }

        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: nearbyCandidates.map(\.id))
        .navigationTitle("Pair Manually")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pairing(startsWithScanner: Bool = false,
                         candidate: GlassyStreamEndpointCandidate? = nil,
                         showsCloseButton: Bool = false) -> some View {
        GlassyStreamPairingView(
            machine: machine,
            fixedCandidate: candidate,
            startsWithScanner: startsWithScanner,
            isEmbedded: true,
            onPaired: { dismiss() },
            onClose: showsCloseButton ? { dismiss() } : nil,
            pairAndConnect: pairAndConnect
        )
    }

    private func screenSharing(showsCloseButton: Bool = false) -> some View {
        ScreenSharingSetupView(store: store, machine: machine) { prepared, password in
            connectScreenSharing(prepared, password)
            dismiss()
        }
        .toolbar {
            if showsCloseButton { closeButton }
        }
    }

    @ToolbarContentBuilder
    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("connection.add-mac.close")
        }
    }

    private var nearbyCandidates: [GlassyStreamEndpointCandidate] {
        var nearbyMachine = machine
        nearbyMachine.host = ""
        nearbyMachine.name = ""
        nearbyMachine.glassyHostIdentifier = nil
        nearbyMachine.glassyHostName = nil
        nearbyMachine.glassyHostAddresses = []
        return GlassyStreamEndpoint.candidates(for: nearbyMachine, discoveredHosts: hostBrowser.hosts)
            .filter { $0.source == .bonjour }
    }

    private func optionRow(title: String, detail: LocalizedStringKey, symbol: String,
                           showsChevron: Bool = true) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }
}
