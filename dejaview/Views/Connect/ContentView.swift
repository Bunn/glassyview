import SwiftUI
import OSLog

struct ContentView<Session: RemoteSessionControlling,
                   Browser: BonjourBrowsing,
                   Store: MachineStoring,
                   Router: AppIntentRouting>: View {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var session: Session
    @StateObject private var glassySession: GlassyStreamRemoteSession
    @State private var browser: Browser
    @State private var store: Store
    @State private var intentRouter: Router
    @State private var networkPathObserver = NetworkPathObserver()
    @State private var glassyHostBrowser = GlassyHostBrowser()
    private let wakeOnLANSender: any WakeOnLANSending

    @State private var selectedSection: ConnectSection? = .hosts
    @State private var searchText = ""

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var isOnboardingPresented = false
    @State private var isSessionPresented = false
    @State private var isSettingsPresented = false

    @State private var editingMachine: SavedMachine?
    @State private var editingPassword = ""
    @State private var pendingConnectionMachine: SavedMachine?
    @State private var pendingConnectionPassword = ""
    @State private var glassyPairingRequest: GlassyStreamPairingRequest?
    @State private var preparedGlassySession: PreparedGlassySession?
    @State private var glassyConnectTask: Task<Void, Never>?
    @State private var pendingDeletionMachine: SavedMachine?
    @State private var isDeleteConfirmationPresented = false
    @State private var isClearRecentConnectionsConfirmationPresented = false
    @State private var sessionMachine: SavedMachine?
    @State private var sessionPreferences = SessionPreferences.default
    @State private var sessionHistoryContext: SessionHistoryContext?
    @State private var machineReachabilityStatuses: [UUID: MachineReachabilityStatus] = [:]
    @State private var machineReachabilityEndpoints: [UUID: String] = [:]
    @State private var reachabilityProbeGeneration = 0
    @State private var shouldSkipNextSceneActiveRefresh = true
    @State private var wakingMachineID: UUID?
    @State private var wakeRequestID: UUID?
    @State private var wakeTask: Task<Void, Never>?
    @State private var wakeFailureMessage = ""
    @State private var isWakeFailurePresented = false
    @State private var glassyConnectionFailureMessage = ""
    @State private var isGlassyConnectionFailurePresented = false
    @State private var glassyConnectionFailureMachine: SavedMachine?

    private let appleScreenSharingHelpURL = URL(string: "https://support.apple.com/guide/mac-help/turn-screen-sharing-on-or-off-mh11848/mac")!
    private let reachabilityRefreshInterval: Duration = .seconds(30)
    private let wakeReachabilityAttemptCount = 20
    private let wakeReachabilityPollInterval: Duration = .seconds(2)

    init(dependencies: AppDependencies<Session, Browser, Store, Router>) {
        _session = StateObject(wrappedValue: dependencies.makeSession())
        _glassySession = StateObject(wrappedValue: GlassyStreamRemoteSession())
        _browser = State(initialValue: dependencies.makeBrowser())
        _store = State(initialValue: dependencies.makeStore())
        _intentRouter = State(initialValue: dependencies.makeIntentRouter())
        wakeOnLANSender = dependencies.wakeOnLANSender
    }

    var body: some View {
        NavigationSplitView {
            ConnectSidebarView(selection: $selectedSection,
                               hostCount: store.machines.count + resolvedServices.count,
                               recentCount: store.recentConnections.count,
                               nearbyCount: resolvedServices.count)
        } detail: {
            detailRoot
        }
        .navigationSplitViewStyle(.balanced)
        .fullScreenCover(isPresented: $isSessionPresented, onDismiss: handleSessionDismissed) {
            if sessionMachine?.connectionMode == .glassyStream {
                SessionView(session: glassySession,
                            preferences: $sessionPreferences,
                            sessionTitle: sessionMachine?.displayName ?? "Remote Mac",
                            glassyStream: glassySession.controller)
            } else {
                SessionView(session: session,
                            preferences: $sessionPreferences,
                            sessionTitle: sessionMachine?.displayName ?? "Remote Mac")
            }
        }
        .fullScreenCover(isPresented: $isOnboardingPresented) {
            NavigationStack {
                OnboardingView(onComplete: completeOnboarding)
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsView()
                    .environment(glassyHostBrowser)
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done", action: dismissSettings)
                        }
                    }
            }
        }
        .sheet(item: $editingMachine, onDismiss: connectPendingMachine) { machine in
            EditMachineView(store: store,
                            machine: machine,
                            password: editingPassword,
                            connectAfterDismiss: queueConnectionAfterEditor)
        }
        .sheet(item: $glassyPairingRequest, onDismiss: finishGlassyPairing) { request in
            GlassyStreamPairingView(
                machine: request.machine,
                initialErrorMessage: request.initialErrorMessage,
                fixedCandidate: request.fixedCandidate
            ) { candidate, bootstrapCredential in
                try await pairGlassyStream(
                    candidate: candidate,
                    bootstrapCredential: bootstrapCredential,
                    request: request
                )
            }
            .environment(glassyHostBrowser)
        }
        .alert("Delete Machine?",
               isPresented: $isDeleteConfirmationPresented,
               presenting: pendingDeletionMachine) { machine in
            Button("Delete", role: .destructive) {
                delete(machine)
            }

            Button("Cancel", role: .cancel) {
                pendingDeletionMachine = nil
            }
        } message: { machine in
            Text("This removes \(machine.displayName) from your saved machines.")
        }
        .alert("Wake on LAN", isPresented: $isWakeFailurePresented) {
        } message: {
            Text(wakeFailureMessage)
        }
        .alert("Glassy Stream", isPresented: $isGlassyConnectionFailurePresented) {
            if let machine = glassyConnectionFailureMachine {
                Button("Edit Machine") {
                    glassyConnectionFailureMachine = nil
                    edit(machine)
                }
            }

            Button("OK", role: .cancel) {
                glassyConnectionFailureMachine = nil
            }
        } message: {
            Text(glassyConnectionFailureMessage)
        }
        .onAppear {
            AppLog.ui.info("Connect view appeared; starting nearby Mac discovery")
            browser.start()
            glassyHostBrowser.start()
            networkPathObserver.start()
            presentOnboardingIfNeeded()
            handlePendingIntentRequest()

            if scenePhase == .active {
                shouldSkipNextSceneActiveRefresh = false
            }
        }
        .onDisappear {
            glassyHostBrowser.stop()
            networkPathObserver.stop()
        }
        .onChange(of: intentRouter.request) { _, request in
            guard let request else { return }
            handleIntentRequest(request)
        }
        .onChange(of: session.status) { _, status in
            guard sessionMachine?.connectionMode == .vnc else { return }
            handleSessionStatusChanged(status)
        }
        .onChange(of: glassySession.status) { _, status in
            guard sessionMachine?.connectionMode == .glassyStream else { return }
            handleSessionStatusChanged(status)
        }
        .onChange(of: selectedSection) { _, section in
            logSectionSelection(section)
        }
        .onChange(of: networkPathObserver.snapshot) { oldSnapshot, newSnapshot in
            guard oldSnapshot != nil, let newSnapshot else { return }

            Task {
                await refreshForNetworkPathChange(newSnapshot)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                suspendGlassyForBackground()
                return
            }

            guard newPhase == .active else { return }

            let resumedGlassySession = glassySession.resumeAfterBackground()
            if resumedGlassySession {
                AppLog.ui.info("Resuming the presented Glassy Stream after foregrounding")
            }

            guard !shouldSkipNextSceneActiveRefresh else {
                shouldSkipNextSceneActiveRefresh = false
                AppLog.ui.debug("Skipping initial scene active machine refresh")
                return
            }

            Task {
                await refreshMachineList(reason: "sceneBecameActive", marksMachinesChecking: false)
            }
        }
        .task(id: machineReachabilitySignature) {
            await monitorSavedMachineReachability()
        }
    }

    private func suspendGlassyForBackground() {
        let hasActiveGlassyWork = glassyConnectTask != nil
            || glassyPairingRequest != nil
            || preparedGlassySession != nil
            || sessionMachine?.connectionMode == .glassyStream
        guard hasActiveGlassyWork else { return }

        if sessionMachine?.connectionMode == .glassyStream,
           glassySession.suspendForBackground() {
            AppLog.ui.info("Suspending the presented Glassy Stream while the app is in the background")
            return
        }

        AppLog.ui.info("Cancelling an unfinished Glassy Stream connection because the app entered the background")
        glassyConnectTask?.cancel()
        glassyConnectTask = nil
        glassyPairingRequest = nil
        preparedGlassySession = nil
        glassySession.disconnect()
    }

    // MARK: - Detail

    private var currentSection: ConnectSection {
        selectedSection ?? .hosts
    }

    private var detailView: some View {
        connectDetailView
    }

    private var detailRoot: some View {
        detailView
            .navigationTitle(currentSection.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search")
            .toolbar {
                detailToolbar
            }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if currentSection != .recents {
                Button("Add Host", systemImage: "plus", action: addMachine)
            }

            Menu("More", systemImage: "ellipsis.circle") {
                if currentSection == .recents {
                    Button("Refresh Recents", systemImage: "arrow.clockwise", action: refreshRecentConnections)

                    Button("Clear Recent Sessions",
                           systemImage: "trash",
                           role: .destructive,
                           action: confirmClearRecentConnections)
                        .disabled(store.recentConnections.isEmpty)
                } else {
                    Button("Refresh Machines", systemImage: "arrow.clockwise", action: refreshMachines)
                }

                Divider()
                Button("Settings", systemImage: "gearshape", action: openSettings)
            }
            .confirmationDialog("Clear Recent Sessions?",
                                isPresented: $isClearRecentConnectionsConfirmationPresented,
                                titleVisibility: .visible) {
                Button("Clear All", role: .destructive, action: clearRecentConnections)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes all connection history.")
            }
        }
    }

    private var connectDetailView: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                detailContentStack
            }
            .refreshable {
                await refreshCurrentSection()
            }
        }
    }

    private var detailContentStack: some View {
        VStack(alignment: .leading, spacing: 24) {
            ConnectHeaderView(section: currentSection)

            switch currentSection {
            case .hosts:
                hostsContent
            case .recents:
                RecentConnectionsView(entries: filteredRecentConnections,
                                      isSearching: isSearching,
                                      canReconnectDirectly: canReconnectDirectly(to:),
                                      connect: connect(to:),
                                      delete: deleteRecentConnection(_:))
            case .nearby:
                nearbyContent
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: 1280, alignment: .leading)
    }

    @ViewBuilder
    private var hostsContent: some View {
        if filteredMachines.isEmpty && filteredServices.isEmpty {
            if hasUnresolvedServices && !isSearching {
                scanningPanel
            } else {
                unavailableHostsView
            }
        } else {
            hostGrid
        }

        manualPanel
    }

    @ViewBuilder
    private var nearbyContent: some View {
        if filteredServices.isEmpty {
            if isSearching {
                ContentUnavailableView.search
            } else {
                scanningPanel
            }
        } else {
            nearbyGrid
        }
    }

    @ViewBuilder
    private var hostGrid: some View {
        GlassEffectContainer(spacing: 16) {
            hostGridContent
        }
    }

    private var hostGridContent: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
            ForEach(filteredMachines) { machine in
                SavedMachineTile(machine: machine,
                                 reachabilityStatus: reachabilityStatus(for: machine),
                                 isWaking: wakingMachineID == machine.id,
                                 connect: { connect(to: machine) },
                                 wakeAndConnect: wakeAction(for: machine),
                                 cancelWake: cancelWakeAttempt,
                                 edit: { edit(machine) },
                                 delete: { confirmDelete(machine) })
            }

            ForEach(filteredServices) { service in
                DiscoveredServiceTile(service: service) {
                    addMachine(for: service)
                }
            }
        }
    }

    @ViewBuilder
    private var nearbyGrid: some View {
        GlassEffectContainer(spacing: 16) {
            nearbyGridContent
        }
    }

    private var nearbyGridContent: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
            ForEach(filteredServices) { service in
                DiscoveredServiceTile(service: service) {
                    addMachine(for: service)
                }
            }
        }
    }

    private var scanningPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ProgressView()

                VStack(alignment: .leading, spacing: 3) {
                    Text("Looking for Macs")
                        .font(.headline)

                    Text("Screen Sharing hosts appear here automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Link(destination: appleScreenSharingHelpURL) {
                Label("Not seeing your Mac?", systemImage: "questionmark.circle")
            }
            .buttonStyle(.glass)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .glassPanel(cornerRadius: 28)
    }

    @ViewBuilder
    private var unavailableHostsView: some View {
        if isSearching {
            ContentUnavailableView.search
        } else {
            ContentUnavailableView("No Hosts",
                                   systemImage: "rectangle.connected.to.line.below",
                                   description: Text("Add a host, discover one nearby, or connect manually."))
                .padding(24)
                .frame(maxWidth: .infinity)
                .glassPanel(cornerRadius: 28)
        }
    }

    private var manualPanel: some View {
        Button("New Machine", systemImage: "plus", action: addMachine)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .buttonStyle(.glassProminent)
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)]
    }

    private var filteredMachines: [SavedMachine] {
        guard isSearching else { return store.machines }

        return store.machines.filter { machine in
            machine.displayName.localizedStandardContains(searchQuery) ||
            machine.subtitle.localizedStandardContains(searchQuery)
        }
    }

    private var filteredServices: [DiscoveredService] {
        guard isSearching else { return resolvedServices }

        return resolvedServices.filter { service in
            service.name.localizedStandardContains(searchQuery) ||
            service.host?.localizedStandardContains(searchQuery) == true
        }
    }

    private var filteredRecentConnections: [ConnectionHistoryEntry] {
        guard isSearching else { return store.recentConnections }

        return store.recentConnections.filter { entry in
            entry.displayName.localizedStandardContains(searchQuery) ||
            entry.subtitle.localizedStandardContains(searchQuery) ||
            entry.outcome.title.localizedStandardContains(searchQuery)
        }
    }

    private var resolvedServices: [DiscoveredService] {
        browser.services.filter(\.isResolved)
    }

    private var hasUnresolvedServices: Bool {
        browser.services.contains { !$0.isResolved }
    }

    private var isSearching: Bool {
        !searchQuery.isEmpty
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var machineReachabilitySignature: String {
        store.machines
            .map { "\($0.id.uuidString)|\(reachabilityEndpointKey(for: $0))" }
            .joined(separator: "\n")
    }

    // MARK: - Actions

    private func addMachine() {
        AppLog.ui.info("Opening New Machine sheet")
        editingPassword = ""
        editingMachine = SavedMachine(name: "", host: "", username: "")
    }

    private func addMachine(for service: DiscoveredService) {
        guard let serviceHost = service.host, let servicePort = service.port else {
            AppLog.ui.warning("Ignored unresolved nearby service '\(service.name, privacy: .public)'")
            return
        }

        AppLog.ui.info("Opening New Machine sheet from nearby service '\(service.name, privacy: .public)' at \(serviceHost, privacy: .public):\(servicePort, privacy: .public)")
        editingPassword = ""
        editingMachine = SavedMachine(name: service.name,
                                      host: serviceHost,
                                      port: servicePort,
                                      username: "")
    }

    private func edit(_ machine: SavedMachine) {
        AppLog.ui.info("Opening Edit Machine sheet for '\(machine.displayName, privacy: .public)'")
        editingPassword = store.password(for: machine)
        editingMachine = machine
    }

    private func confirmDelete(_ machine: SavedMachine) {
        AppLog.ui.info("Showing delete confirmation for '\(machine.displayName, privacy: .public)'")
        pendingDeletionMachine = machine
        isDeleteConfirmationPresented = true
    }

    private func delete(_ machine: SavedMachine) {
        AppLog.ui.info("Deleting saved machine from card menu; id=\(machine.id.uuidString, privacy: .public) name=\(machine.displayName, privacy: .public)")
        pendingDeletionMachine = nil
        isDeleteConfirmationPresented = false

        if editingMachine?.id == machine.id {
            editingMachine = nil
        }

        if pendingConnectionMachine?.id == machine.id {
            pendingConnectionMachine = nil
            pendingConnectionPassword = ""
        }

        if wakingMachineID == machine.id {
            cancelWakeAttempt()
        }

        machineReachabilityStatuses[machine.id] = nil
        machineReachabilityEndpoints[machine.id] = nil
        store.delete(machine)
    }

    private func refreshMachines() {
        Task {
            await refreshMachineList(reason: "toolbar", marksMachinesChecking: false)
        }
    }

    private func refreshRecentConnections() {
        AppLog.ui.info("Refreshing Recents; beforeCount=\(self.store.recentConnections.count, privacy: .public)")
        store.reload()
        AppLog.ui.info("Finished refreshing Recents; afterCount=\(self.store.recentConnections.count, privacy: .public) filteredCount=\(self.filteredRecentConnections.count, privacy: .public) searchActive=\(self.isSearching, privacy: .public)")
    }

    private func logSectionSelection(_ section: ConnectSection?) {
        let sectionName = section?.rawValue ?? "none"
        AppLog.ui.info("Connect section changed; section=\(sectionName, privacy: .public) recentCount=\(self.store.recentConnections.count, privacy: .public) filteredRecentCount=\(self.filteredRecentConnections.count, privacy: .public) searchActive=\(self.isSearching, privacy: .public)")
    }

    @MainActor
    private func refreshCurrentSection() async {
        if currentSection == .recents {
            refreshRecentConnections()
        } else {
            await refreshMachineList(reason: "pullToRefresh", marksMachinesChecking: false)
        }
    }

    private func confirmClearRecentConnections() {
        isClearRecentConnectionsConfirmationPresented = true
    }

    private func clearRecentConnections() {
        isClearRecentConnectionsConfirmationPresented = false
        store.clearRecentConnections()
    }

    private func deleteRecentConnection(_ entry: ConnectionHistoryEntry) {
        store.deleteRecentConnection(entry)
    }

    private func openSettings() {
        isSettingsPresented = true
    }

    private func dismissSettings() {
        isSettingsPresented = false
    }

    private func presentOnboardingIfNeeded() {
        guard !hasCompletedOnboarding else { return }
        isOnboardingPresented = true
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
        isOnboardingPresented = false
    }

    private func refreshNearbyMacs() {
        Task {
            await refreshMachineList(reason: "nearby", marksMachinesChecking: false)
        }
    }

    private func queueConnectionAfterEditor(machine: SavedMachine, password: String) {
        AppLog.ui.info("Queued connection after editor dismiss for \(machine.host, privacy: .public):\(machine.port, privacy: .public)")
        pendingConnectionMachine = machine
        pendingConnectionPassword = password
    }

    private func connectPendingMachine() {
        guard let machine = pendingConnectionMachine else { return }

        AppLog.ui.info("Starting pending direct connection to \(machine.host, privacy: .public):\(machine.port, privacy: .public)")
        pendingConnectionMachine = nil
        connectOrWake(to: machine, password: pendingConnectionPassword)
        pendingConnectionPassword = ""
    }

    private func connect(to machine: SavedMachine) {
        AppLog.ui.info("Starting saved machine connection to '\(machine.displayName, privacy: .public)'")
        connectOrWake(to: machine, password: store.password(for: machine))
    }

    private func connect(to entry: ConnectionHistoryEntry) {
        if let machine = reconnectableMachine(for: entry) {
            AppLog.ui.info("Reconnecting from recent session to saved machine '\(machine.displayName, privacy: .public)'")
            connect(to: machine)
            return
        }

        AppLog.ui.info("Opening connection details for recent session '\(entry.displayName, privacy: .public)'")
        editingPassword = ""
        editingMachine = SavedMachine(name: entry.displayName,
                                      host: entry.host,
                                      port: entry.port,
                                      username: entry.username)
    }

    private func canReconnectDirectly(to entry: ConnectionHistoryEntry) -> Bool {
        reconnectableMachine(for: entry) != nil
    }

    private func reconnectableMachine(for entry: ConnectionHistoryEntry) -> SavedMachine? {
        if let machineID = entry.machineID,
           let machine = store.machine(withID: machineID) {
            return machine
        }

        return store.machines.first { machine in
            machine.host.caseInsensitiveCompare(entry.host) == .orderedSame &&
            machine.port == entry.port &&
            machine.username == entry.username
        }
    }

    private func connectFromIntent(machineID: UUID) {
        guard let machine = store.machine(withID: machineID) else {
            AppLog.ui.warning("Ignored App Intent connection request for missing machine id=\(machineID.uuidString, privacy: .public)")
            return
        }

        selectedSection = .hosts
        searchText = ""
        editingMachine = nil
        connect(to: machine)
    }

    private func openFromIntent(destination: DejaViewDestination) {
        selectedSection = connectSection(for: destination)
        searchText = ""
        editingMachine = nil
    }

    private func refreshNearbyFromIntent() {
        openFromIntent(destination: .nearby)
        refreshNearbyMacs()
    }

    private func disconnectFromIntent() {
        AppLog.ui.info("Disconnecting session from App Intent")
        glassyConnectTask?.cancel()
        glassyConnectTask = nil
        glassyPairingRequest = nil
        preparedGlassySession = nil
        glassySession.disconnect()
        session.disconnect()

        if isSessionPresented {
            isSessionPresented = false
        } else {
            glassySession.reset()
            session.reset()
        }
    }

    private func handleSessionStatusChanged(_ status: RemoteSessionStatus) {
        switch status {
        case .connected:
            guard sessionHistoryContext == nil,
                  let sessionMachine else {
                return
            }

            let connectedAt = Date.now
            let historyID = store.startSession(to: sessionMachine,
                                               connectedAt: connectedAt)
            sessionHistoryContext = SessionHistoryContext(id: historyID)
            AppLog.storage.info("Session history tracking started for '\(sessionMachine.displayName, privacy: .public)'; id=\(historyID.uuidString, privacy: .public) recentCount=\(self.store.recentConnections.count, privacy: .public)")

        case .disconnected(let message):
            finishSessionHistory(outcome: message == nil ? .completed : .interrupted)

        case .idle, .connecting, .reconnecting:
            break
        }
    }

    private func handleSessionDismissed() {
        persistSessionPreferences()
        finishSessionHistory(outcome: .completed)
        glassyConnectTask?.cancel()
        glassyConnectTask = nil
        sessionMachine = nil
        glassySession.reset()
        session.reset()
    }

    private func persistSessionPreferences() {
        guard let sessionMachine,
              store.contains(sessionMachine) else {
            return
        }

        store.setSessionPreferences(sessionPreferences, for: sessionMachine)
    }

    private func finishSessionHistory(outcome: ConnectionHistoryOutcome) {
        guard let sessionHistoryContext else { return }

        store.finishSession(withID: sessionHistoryContext.id,
                            endedAt: .now,
                            outcome: outcome)
        self.sessionHistoryContext = nil
    }

    private func handlePendingIntentRequest() {
        guard let request = intentRouter.request else { return }
        handleIntentRequest(request)
    }

    private func handleIntentRequest(_ request: AppIntentRequest) {
        switch request.action {
        case .connect(let machineID):
            connectFromIntent(machineID: machineID)
        case .open(let destination):
            openFromIntent(destination: destination)
        case .refreshNearby:
            refreshNearbyFromIntent()
        case .disconnect:
            disconnectFromIntent()
        case .reloadMachines:
            Task {
                await refreshMachineList(reason: "appIntentReloadMachines", marksMachinesChecking: false)
            }
        }

        intentRouter.clear(request)
    }

    private func connectSection(for destination: DejaViewDestination) -> ConnectSection {
        switch destination {
        case .hosts:
            .hosts
        case .nearby:
            .nearby
        }
    }

    private func presentVNCSession(for machine: SavedMachine, password: String) {
        cancelWakeAttempt(logCancellation: false)
        AppLog.ui.info("Presenting VNC session for \(machine.host, privacy: .public):\(machine.port, privacy: .public)")
        let preferences = store.contains(machine)
            ? store.sessionPreferences(for: machine)
            : SessionPreferences.default

        sessionMachine = machine
        sessionPreferences = preferences
        sessionHistoryContext = nil
        session.applyPreferences(preferences)
        session.connect(host: machine.host,
                        port: machine.port,
                        username: machine.username,
                        password: password)

        isSessionPresented = true
    }

    private func presentGlassySession(for machine: SavedMachine) {
        cancelWakeAttempt(logCancellation: false)
        AppLog.ui.info("Presenting authenticated Glassy Stream session for '\(machine.displayName, privacy: .public)'")
        let preferences = store.contains(machine)
            ? store.sessionPreferences(for: machine)
            : SessionPreferences.default

        sessionMachine = machine
        sessionPreferences = preferences
        sessionHistoryContext = nil
        glassySession.applyPreferences(preferences)
        isSessionPresented = true

        // Authentication completes before presentation, so the normal status
        // observer may already have seen `.connected` while no machine was active.
        handleSessionStatusChanged(glassySession.status)
    }

    private func connectUsingConfiguredMethod(
        to machine: SavedMachine,
        password: String
    ) {
        switch machine.connectionMode {
        case .vnc:
            glassyConnectTask?.cancel()
            glassyConnectTask = nil
            glassyPairingRequest = nil
            preparedGlassySession = nil
            glassySession.reset()
            presentVNCSession(for: machine, password: password)

        case .glassyStream:
            session.reset()
            beginGlassyStreamConnection(to: machine, vncPassword: password)
        }
    }

    private func beginGlassyStreamConnection(
        to machine: SavedMachine,
        vncPassword: String
    ) {
        glassyConnectTask?.cancel()
        preparedGlassySession = nil
        glassyPairingRequest = nil
        let preferences = store.contains(machine)
            ? store.sessionPreferences(for: machine)
            : SessionPreferences.default
        glassySession.applyPreferences(preferences)

        let expectedHostIdentifier = expectedGlassyHostIdentifier(for: machine)
        guard expectedHostIdentifier != nil else {
            glassySession.reset()
            glassyPairingRequest = GlassyStreamPairingRequest(
                machine: machine,
                vncPassword: vncPassword
            )
            return
        }

        let candidates = GlassyStreamEndpoint.candidates(
            for: machine,
            discoveredHosts: glassyHostBrowser.hosts
        )
        guard !candidates.isEmpty else {
            glassySession.reset()
            showGlassyConnectionFailure(
                "No route to \(machine.displayName) is available. Edit the machine and enter its Tailscale name or 100.x address, or open Glassy Host while both devices are on the same local network.",
                machine: machine
            )
            return
        }

        glassyConnectTask = Task { @MainActor in
            var lastError: Error?

            for candidate in candidates {
                guard !Task.isCancelled else { return }

                do {
                    let authentication = try await glassySession.connect(
                        endpoint: candidate.endpoint,
                        savedMachineID: machine.id,
                        bootstrapCredential: nil,
                        expectedHostIdentifier: expectedHostIdentifier,
                        desiredQuality: preferences.quality,
                        fallbackEndpoints: candidates
                            .filter { $0.id != candidate.id }
                            .map(\.endpoint)
                    )
                    guard !Task.isCancelled else {
                        glassySession.disconnect()
                        return
                    }

                    let authenticatedMachine = saveGlassyHostBinding(
                        for: machine,
                        authentication: authentication,
                        candidate: candidate,
                        vncPassword: vncPassword
                    )
                    glassyConnectTask = nil
                    presentGlassySession(for: authenticatedMachine)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    lastError = error

                    guard !Task.isCancelled else { return }
                    guard shouldTryNextGlassyRoute(after: error) else {
                        glassyConnectTask = nil
                        glassySession.disconnect()

                        if shouldPromptForGlassyPairing(after: error) {
                            glassyPairingRequest = GlassyStreamPairingRequest(
                                machine: machine,
                                vncPassword: vncPassword,
                                initialErrorMessage: pairingPromptMessage(for: error),
                                fixedCandidate: candidate
                            )
                        } else {
                            showGlassyConnectionFailure(
                                glassyConnectionFailureMessage(for: error),
                                machine: machine
                            )
                        }
                        return
                    }
                }
            }

            guard !Task.isCancelled else { return }
            glassyConnectTask = nil
            glassySession.disconnect()
            showGlassyConnectionFailure(
                glassyConnectionFailureMessage(for: lastError),
                machine: machine
            )
        }
    }

    private func pairGlassyStream(
        candidate: GlassyStreamEndpointCandidate,
        bootstrapCredential: GlassyStreamBootstrapCredential,
        request: GlassyStreamPairingRequest
    ) async throws {
        let preferences = store.contains(request.machine)
            ? store.sessionPreferences(for: request.machine)
            : SessionPreferences.default
        glassySession.applyPreferences(preferences)
        let authentication = try await glassySession.connect(
            endpoint: candidate.endpoint,
            savedMachineID: request.machine.id,
            bootstrapCredential: bootstrapCredential,
            expectedHostIdentifier: expectedGlassyHostIdentifier(for: request.machine),
            desiredQuality: preferences.quality
        )
        let authenticatedMachine = saveGlassyHostBinding(
            for: request.machine,
            authentication: authentication,
            candidate: candidate,
            vncPassword: request.vncPassword
        )

        preparedGlassySession = PreparedGlassySession(
            machine: authenticatedMachine
        )
    }

    private func finishGlassyPairing() {
        glassyPairingRequest = nil

        guard let preparedGlassySession else {
            glassySession.disconnect()
            return
        }

        self.preparedGlassySession = nil
        presentGlassySession(for: preparedGlassySession.machine)
    }

    private func expectedGlassyHostIdentifier(for machine: SavedMachine) -> Data? {
        guard let encodedIdentifier = machine.glassyHostIdentifier,
              let identifier = Data(base64Encoded: encodedIdentifier),
              identifier.count == GlassyStreamWire.identifierLength else {
            return nil
        }
        return identifier
    }

    private func saveGlassyHostBinding(
        for machine: SavedMachine,
        authentication: GlassyStreamAuthentication,
        candidate: GlassyStreamEndpointCandidate,
        vncPassword: String
    ) -> SavedMachine {
        var authenticatedMachine = machine
        authenticatedMachine.glassyHostIdentifier = authentication.hostIdentifier.base64EncodedString()

        let authenticatedName = authentication.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        authenticatedMachine.glassyHostName = authenticatedName.isEmpty
            ? candidate.name
            : authenticatedName

        // Normalize legacy records and inline host:port input only after that
        // exact direct route has authenticated as the pinned Glassy Host.
        if let directAddress = candidate.directAddress {
            authenticatedMachine.host = directAddress.host
            authenticatedMachine.port = directAddress.port
        }

        if store.contains(machine) {
            store.update(authenticatedMachine, password: vncPassword)
        }
        return authenticatedMachine
    }

    private func shouldTryNextGlassyRoute(after error: Error) -> Bool {
        guard let sessionError = error as? GlassyStreamSessionError else {
            return false
        }

        switch sessionError {
        case .connectionEndedBeforeAuthentication:
            return true
        case .transport(let clientError):
            switch clientError {
            case .connectionFailed, .connectionClosed, .authenticationTimedOut:
                return true
            case .alreadyConnecting,
                 .cancelled,
                 .pairingCodeRequired,
                 .invalidPairingCode,
                 .invalidPairingPassword,
                 .pairingPasswordRequiresTailscale,
                 .pairingPasswordUnsupported,
                 .pairingPasswordDerivationFailed,
                 .authenticationRejected,
                 .hostIdentityMismatch,
                 .directInputUnsupported,
                 .unsupportedHostVersion,
                 .protocolViolation,
                 .credentialStoreFailed:
                return false
            }
        case .cancelled, .videoReadinessTimedOut, .video:
            return false
        }
    }

    private func shouldPromptForGlassyPairing(after error: Error) -> Bool {
        guard let sessionError = error as? GlassyStreamSessionError,
              case let .transport(clientError) = sessionError else {
            return false
        }

        switch clientError {
        case .pairingCodeRequired, .authenticationRejected:
            return true
        default:
            return false
        }
    }

    private func glassyConnectionFailureMessage(for error: Error?) -> String {
        guard let error else {
            return "Could not reach Glassy Host. Check that Tailscale and Glassy Host are running, then try again."
        }

        let description = error.localizedDescription
        guard let localizedError = error as? LocalizedError,
              let suggestion = localizedError.recoverySuggestion,
              !suggestion.isEmpty else {
            return description
        }
        return "\(description)\n\n\(suggestion)"
    }

    private func showGlassyConnectionFailure(
        _ message: String,
        machine: SavedMachine? = nil
    ) {
        glassyConnectionFailureMessage = message
        glassyConnectionFailureMachine = machine
        isGlassyConnectionFailurePresented = true
    }

    private func pairingPromptMessage(for error: Error?) -> String? {
        guard let error else { return nil }

        if let sessionError = error as? GlassyStreamSessionError,
           case .transport(.pairingCodeRequired) = sessionError {
            return nil
        }
        if let sessionError = error as? GlassyStreamSessionError,
           case .transport(.authenticationRejected) = sessionError {
            return "The saved approval was not accepted. Use the current one-time code, or the reusable pairing password configured in Glassy Host, to pair again."
        }
        return error.localizedDescription
    }

    // MARK: - Wake on LAN

    private func wakeAction(for machine: SavedMachine) -> (() -> Void)? {
        guard machine.connectionMode == .vnc,
              machine.wakeOnLANAddress != nil else { return nil }
        return { wakeAndConnect(to: machine) }
    }

    private func connectOrWake(to machine: SavedMachine, password: String) {
        guard machine.connectionMode == .vnc else {
            connectUsingConfiguredMethod(to: machine, password: password)
            return
        }

        guard machine.wakeOnLANAddress != nil,
              reachabilityStatus(for: machine) != .reachable else {
            connectUsingConfiguredMethod(to: machine, password: password)
            return
        }

        startWakeAndConnect(to: machine, password: password)
    }

    private func wakeAndConnect(to machine: SavedMachine) {
        startWakeAndConnect(to: machine, password: store.password(for: machine))
    }

    private func startWakeAndConnect(to machine: SavedMachine, password: String) {
        guard let macAddress = machine.wakeOnLANAddress else {
            connectUsingConfiguredMethod(to: machine, password: password)
            return
        }

        guard wakingMachineID != machine.id else {
            AppLog.wakeOnLAN.debug("Ignored duplicate wake request for machine id=\(machine.id.uuidString, privacy: .public)")
            return
        }

        cancelWakeAttempt(logCancellation: false)

        let requestID = UUID()
        wakeRequestID = requestID
        wakingMachineID = machine.id
        AppLog.wakeOnLAN.info("Starting wake-and-connect for '\(machine.displayName, privacy: .public)'; id=\(machine.id.uuidString, privacy: .public)")

        wakeTask = Task { @MainActor in
            await performWakeAndConnect(to: machine,
                                        password: password,
                                        macAddress: macAddress,
                                        requestID: requestID)
        }
    }

    @MainActor
    private func performWakeAndConnect(to machine: SavedMachine,
                                       password: String,
                                       macAddress: MACAddress,
                                       requestID: UUID) async {
        defer {
            finishWakeAttempt(requestID: requestID)
        }

        do {
            try await wakeOnLANSender.sendMagicPacket(to: macAddress)
        } catch is CancellationError {
            return
        } catch {
            AppLog.wakeOnLAN.error("Wake-on-LAN send failed for id=\(machine.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            showWakeFailure("\(error.localizedDescription) Check that Local Network access is enabled and try again.")
            return
        }

        for attempt in 1...wakeReachabilityAttemptCount {
            guard !Task.isCancelled,
                  wakeRequestID == requestID else {
                return
            }

            if attempt > 1 {
                do {
                    try await Task.sleep(for: wakeReachabilityPollInterval)
                } catch {
                    return
                }
            }

            let status = await MachineReachabilityProber.status(host: machine.host,
                                                                 port: machine.port,
                                                                 timeout: .seconds(1))
            machineReachabilityStatuses[machine.id] = status
            AppLog.wakeOnLAN.debug("Wake reachability probe completed; id=\(machine.id.uuidString, privacy: .public) attempt=\(attempt, privacy: .public) status=\(status.title, privacy: .public)")

            guard status == .reachable else { continue }
            guard store.contains(machine) else {
                AppLog.wakeOnLAN.info("Stopped wake-and-connect because machine was removed; id=\(machine.id.uuidString, privacy: .public)")
                return
            }

            AppLog.wakeOnLAN.info("Machine became reachable after Wake-on-LAN; id=\(machine.id.uuidString, privacy: .public) attempt=\(attempt, privacy: .public)")
            connectUsingConfiguredMethod(to: machine, password: password)
            return
        }

        AppLog.wakeOnLAN.warning("Machine did not become reachable after Wake-on-LAN; id=\(machine.id.uuidString, privacy: .public) attempts=\(self.wakeReachabilityAttemptCount, privacy: .public)")
        showWakeFailure("The wake packet was sent, but \(machine.displayName) did not become reachable within one minute. Check that “Wake for network access” is enabled and that both devices are on the same local network.")
    }

    private func finishWakeAttempt(requestID: UUID) {
        guard wakeRequestID == requestID else { return }
        wakeTask = nil
        wakeRequestID = nil
        wakingMachineID = nil
    }

    private func cancelWakeAttempt() {
        cancelWakeAttempt(logCancellation: true)
    }

    private func cancelWakeAttempt(logCancellation: Bool) {
        guard wakeTask != nil || wakingMachineID != nil else { return }

        if logCancellation, let wakingMachineID {
            AppLog.wakeOnLAN.info("Cancelled wake-and-connect; id=\(wakingMachineID.uuidString, privacy: .public)")
        }

        wakeTask?.cancel()
        wakeTask = nil
        wakeRequestID = nil
        wakingMachineID = nil
    }

    private func showWakeFailure(_ message: String) {
        wakeFailureMessage = message
        isWakeFailurePresented = true
    }

    // MARK: - Reachability

    private func reachabilityStatus(for machine: SavedMachine) -> MachineReachabilityStatus {
        if wakingMachineID == machine.id {
            return .waking
        }

        if machine.connectionMode == .glassyStream {
            let savedName = machine.glassyHostName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isNearby = savedName.map { name in
                !name.isEmpty && glassyHostBrowser.hosts.contains(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                })
            } ?? false

            if isNearby {
                return .reachable
            }

            if GlassyStreamEndpoint.directCandidate(for: machine) != nil {
                return machineReachabilityStatuses[machine.id] ?? .checking
            }

            guard savedName?.isEmpty == false else { return .checking }
            return glassyHostBrowser.state == .searching ? .checking : .unreachable
        }

        return machineReachabilityStatuses[machine.id] ?? .checking
    }

    @MainActor
    private func monitorSavedMachineReachability() async {
        AppLog.reachability.info("Starting saved machine reachability monitor")
        pruneSavedMachineReachabilityState()

        while !Task.isCancelled {
            AppLog.reachability.debug("Saved machine reachability monitor tick")
            await refreshSavedMachineReachability()

            guard !Task.isCancelled else { break }

            try? await Task.sleep(for: reachabilityRefreshInterval)
        }

        AppLog.reachability.info("Saved machine reachability monitor stopped")
    }

    @MainActor
    private func refreshSavedMachineReachability() async {
        await refreshSavedMachineReachability(showChecking: false)
    }

    @MainActor
    private func refreshSavedMachineReachability(showChecking: Bool) async {
        let machines = store.machines

        guard !machines.isEmpty else {
            AppLog.reachability.info("Skipping saved machine reachability refresh because there are no saved machines")
            machineReachabilityStatuses.removeAll()
            machineReachabilityEndpoints.removeAll()
            return
        }

        let previousGeneration = reachabilityProbeGeneration
        AppLog.reachability.info("Starting saved machine reachability refresh; count=\(machines.count, privacy: .public) showChecking=\(showChecking, privacy: .public) previousGeneration=\(previousGeneration, privacy: .public)")
        prepareReachabilityState(for: machines)

        if showChecking {
            AppLog.reachability.debug("Marking saved machines as checking before probe refresh")
            machines.forEach { machineReachabilityStatuses[$0.id] = .checking }
        }

        reachabilityProbeGeneration += 1
        let generation = reachabilityProbeGeneration
        let startedAt = ContinuousClock.now

        await withTaskGroup(of: (UUID, String, MachineReachabilityStatus).self) { group in
            for machine in machines {
                let id = machine.id
                let endpoint = reachabilityEndpoint(for: machine)
                let host = endpoint.host
                let port = endpoint.port
                let probeTimeout: Duration = machine.connectionMode == .glassyStream
                    ? .seconds(5)
                    : .seconds(2)
                let endpointKey = reachabilityEndpointKey(host: host, port: port)

                AppLog.reachability.debug("Queueing saved machine reachability probe; generation=\(generation, privacy: .public) id=\(id.uuidString, privacy: .public) name=\(machine.displayName, privacy: .public) endpoint=\(endpointKey, privacy: .public)")
                group.addTask {
                    await MainActor.run {
                        AppLog.reachability.debug("Launching saved machine reachability probe; generation=\(generation, privacy: .public) id=\(id.uuidString, privacy: .public) endpoint=\(endpointKey, privacy: .public)")
                    }
                    let status = await MachineReachabilityProber.status(
                        host: host,
                        port: port,
                        timeout: probeTimeout
                    )
                    return (id, endpointKey, status)
                }
            }

            for await (id, endpointKey, status) in group {
                guard reachabilityProbeGeneration == generation else {
                    AppLog.reachability.info("Discarding saved machine reachability generation because a newer refresh started; generation=\(generation, privacy: .public) currentGeneration=\(reachabilityProbeGeneration, privacy: .public)")
                    group.cancelAll()
                    return
                }

                if Task.isCancelled {
                    AppLog.reachability.info("Saved machine reachability refresh task is cancelled, applying completed result anyway; generation=\(generation, privacy: .public) id=\(id.uuidString, privacy: .public) endpoint=\(endpointKey, privacy: .public)")
                }

                guard machineReachabilityEndpoints[id] == endpointKey else {
                    let currentEndpoint = machineReachabilityEndpoints[id] ?? "missing"
                    AppLog.reachability.info("Skipping stale saved machine reachability result; generation=\(generation, privacy: .public) id=\(id.uuidString, privacy: .public) resultEndpoint=\(endpointKey, privacy: .public) currentEndpoint=\(currentEndpoint, privacy: .public) status=\(status.title, privacy: .public)")
                    continue
                }

                machineReachabilityStatuses[id] = status
                AppLog.reachability.info("Saved machine reachability result applied; generation=\(generation, privacy: .public) id=\(id.uuidString, privacy: .public) endpoint=\(endpointKey, privacy: .public) status=\(status.title, privacy: .public)")
            }
        }

        let elapsed = String(describing: startedAt.duration(to: .now))
        AppLog.reachability.info("Finished saved machine reachability refresh; generation=\(generation, privacy: .public) elapsed=\(elapsed, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
    }

    @MainActor
    private func refreshMachineList(reason: String, marksMachinesChecking: Bool) async {
        AppLog.ui.info("Refreshing machine list; reason=\(reason, privacy: .public) marksMachinesChecking=\(marksMachinesChecking, privacy: .public)")
        store.reload()
        restartNearbyMacDiscovery(keepingCurrentServices: true)
        await refreshSavedMachineReachability(showChecking: marksMachinesChecking)
    }

    @MainActor
    private func refreshForNetworkPathChange(_ snapshot: NetworkPathSnapshot) async {
        AppLog.ui.info("Network path changed; \(snapshot.logDescription, privacy: .public)")
        store.reload()

        switch snapshot.status {
        case .satisfied:
            restartNearbyMacDiscovery(keepingCurrentServices: true)
            await refreshSavedMachineReachability(showChecking: true)
        case .requiresConnection, .unsatisfied:
            restartNearbyMacDiscovery(keepingCurrentServices: false)
            setSavedMachineReachabilityStatuses(.unreachable)
        }
    }

    private func prepareReachabilityState(for machines: [SavedMachine]) {
        let activeIDs = Set(machines.map(\.id))
        let previousStatusCount = machineReachabilityStatuses.count
        let previousEndpointCount = machineReachabilityEndpoints.count

        machineReachabilityStatuses = machineReachabilityStatuses.filter { activeIDs.contains($0.key) }
        machineReachabilityEndpoints = machineReachabilityEndpoints.filter { activeIDs.contains($0.key) }

        let prunedStatusCount = previousStatusCount - machineReachabilityStatuses.count
        let prunedEndpointCount = previousEndpointCount - machineReachabilityEndpoints.count
        if prunedStatusCount > 0 || prunedEndpointCount > 0 {
            AppLog.reachability.debug("Pruned saved machine reachability state; statusCount=\(prunedStatusCount, privacy: .public) endpointCount=\(prunedEndpointCount, privacy: .public)")
        }

        for machine in machines {
            let endpointKey = reachabilityEndpointKey(for: machine)

            if machineReachabilityEndpoints[machine.id] != endpointKey {
                let previousEndpoint = machineReachabilityEndpoints[machine.id] ?? "missing"
                AppLog.reachability.debug("Saved machine reachability endpoint changed; id=\(machine.id.uuidString, privacy: .public) name=\(machine.displayName, privacy: .public) previous=\(previousEndpoint, privacy: .public) current=\(endpointKey, privacy: .public)")
                machineReachabilityEndpoints[machine.id] = endpointKey
                machineReachabilityStatuses[machine.id] = .checking
            } else if machineReachabilityStatuses[machine.id] == nil {
                AppLog.reachability.debug("Saved machine reachability status missing; id=\(machine.id.uuidString, privacy: .public) name=\(machine.displayName, privacy: .public) endpoint=\(endpointKey, privacy: .public)")
                machineReachabilityStatuses[machine.id] = .checking
            }
        }
    }

    private func pruneSavedMachineReachabilityState() {
        let activeIDs = Set(store.machines.map(\.id))

        machineReachabilityStatuses = machineReachabilityStatuses.filter { activeIDs.contains($0.key) }
        machineReachabilityEndpoints = machineReachabilityEndpoints.filter { activeIDs.contains($0.key) }
    }

    private func restartNearbyMacDiscovery(keepingCurrentServices: Bool) {
        browser.restart(keepingCurrentServices: keepingCurrentServices)
        glassyHostBrowser.restart(keepingCurrentHosts: keepingCurrentServices)
    }

    private func setSavedMachineReachabilityStatuses(_ status: MachineReachabilityStatus) {
        reachabilityProbeGeneration += 1
        AppLog.reachability.info("Setting all saved machine reachability statuses; status=\(status.title, privacy: .public) generation=\(reachabilityProbeGeneration, privacy: .public) count=\(store.machines.count, privacy: .public)")
        prepareReachabilityState(for: store.machines)

        for machine in store.machines {
            machineReachabilityStatuses[machine.id] = status
        }
    }

    private func reachabilityEndpointKey(for machine: SavedMachine) -> String {
        let endpoint = reachabilityEndpoint(for: machine)
        return reachabilityEndpointKey(host: endpoint.host, port: endpoint.port)
    }

    private func reachabilityEndpoint(for machine: SavedMachine) -> (host: String, port: UInt16) {
        if machine.connectionMode == .glassyStream,
           let directAddress = GlassyStreamEndpoint.directCandidate(for: machine)?.directAddress {
            return (directAddress.host, directAddress.port)
        }

        return (
            machine.host.trimmingCharacters(in: .whitespacesAndNewlines),
            machine.port
        )
    }

    private func reachabilityEndpointKey(host: String, port: UInt16) -> String {
        "\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port)"
    }
}

private struct GlassyStreamPairingRequest: Identifiable {
    let machine: SavedMachine
    let vncPassword: String
    var initialErrorMessage: String? = nil
    var fixedCandidate: GlassyStreamEndpointCandidate? = nil

    var id: UUID { machine.id }
}

private struct PreparedGlassySession {
    let machine: SavedMachine
}

extension ContentView where Session == VNCSession,
                            Browser == BonjourBrowser,
                            Store == MachineStore,
                            Router == AppIntentRouter {
    @MainActor
    init() {
        self.init(dependencies: .live)
    }
}

#Preview {
    ContentView()
        .environment(SubscriptionStore())
}
