import AppIntents

struct ConnectSavedMachineIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Computer"
    static let description = IntentDescription("Open Glassy Desk and connect to a saved computer.")
    static let openAppWhenRun = true

    @Parameter(title: "Computer")
    var machine: SavedMachineEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Connect to \(\.$machine)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppIntentRouter.shared.requestConnection(to: machine.id)
        return .result(dialog: "Connecting to \(machine.displayName).")
    }
}

struct DejaViewShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectSavedMachineIntent(),
                    phrases: [
                        "Connect to a computer with \(.applicationName)",
                        "Start a remote session with \(.applicationName)",
                        "Open a saved computer with \(.applicationName)"
                    ],
                    shortTitle: "Connect",
                    systemImageName: "rectangle.connected.to.line.below")
        AppShortcut(intent: OpenDejaViewIntent(),
                    phrases: [
                        "Open \(.applicationName)",
                        "Show hosts in \(.applicationName)"
                    ],
                    shortTitle: "Open",
                    systemImageName: "macwindow")
        AppShortcut(intent: RefreshNearbyMacsIntent(),
                    phrases: [
                        "Refresh nearby computers in \(.applicationName)",
                        "Find nearby computers with \(.applicationName)"
                    ],
                    shortTitle: "Refresh Nearby",
                    systemImageName: "arrow.clockwise")
        AppShortcut(intent: AddSavedMachineIntent(),
                    phrases: [
                        "Add a computer to \(.applicationName)",
                        "Save a computer in \(.applicationName)"
                    ],
                    shortTitle: "Add Computer",
                    systemImageName: "plus")
        AppShortcut(intent: DisconnectRemoteSessionIntent(),
                    phrases: [
                        "Disconnect \(.applicationName)",
                        "End remote session in \(.applicationName)"
                    ],
                    shortTitle: "Disconnect",
                    systemImageName: "xmark.circle")
    }
}
