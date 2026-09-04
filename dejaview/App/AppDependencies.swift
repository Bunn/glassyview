struct AppDependencies<Session: RemoteSessionControlling,
                       Browser: BonjourBrowsing,
                       Store: MachineStoring,
                       Router: AppIntentRouting> {
    let makeSession: () -> Session
    let makeBrowser: () -> Browser
    let makeStore: () -> Store
    let makeIntentRouter: () -> Router
    let wakeOnLANSender: any WakeOnLANSending
    let widgetSnapshotPublisher: any WidgetSnapshotPublishing
}

extension AppDependencies where Session == VNCSession,
                                Browser == BonjourBrowser,
                                Store == MachineStore,
                                Router == AppIntentRouter {
    @MainActor
    static var live: Self {
        let intentRouter = AppIntentRouter.shared
        let widgetSnapshotPublisher = WidgetSnapshotPublisher()

        return AppDependencies(makeSession: VNCSession.init,
                               makeBrowser: BonjourBrowser.init,
                               makeStore: {
                                   MachineStore(
                                       repository: SwiftDataSavedMachineRepository.shared,
                                       widgetSnapshotPublisher: widgetSnapshotPublisher
                                   )
                               },
                               makeIntentRouter: { intentRouter },
                               wakeOnLANSender: WakeOnLANService(),
                               widgetSnapshotPublisher: widgetSnapshotPublisher)
    }
}
