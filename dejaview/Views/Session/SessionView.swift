import SwiftUI
import OSLog

/// Full-screen remote session with floating Liquid Glass controls.
struct SessionView<Session: RemoteSessionControlling>: View {
    @ObservedObject var session: Session
    @Binding private var preferences: SessionPreferences
    let sessionTitle: String
    let glassyStream: GlassyStreamSessionController?
    @Environment(SubscriptionStore.self) private var subscriptionStore
    @Environment(\.analyticsTracker) private var analytics
    @Environment(\.funnelMilestoneTracker) private var funnelMilestones
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var isSessionPaywallPresented = false
    @State private var sessionPaywallSource: PaywallSource = .sessionLimit
    @State private var isFreeSessionTimerInfoPresented = false
    @State private var freeSessionEndDate: Date?
    @State private var shouldEndSessionOnPaywallDismiss = false
    @State private var opensPaywallAfterFreeSessionInfoDismissal = false
    @State private var pendingPaywallEndsSessionOnDismiss = false
    @State private var heldModifierKeys: Set<RemoteModifierKey> = []
    @State private var showsInputBar = false
    @State private var textToSend = ""
    @State private var streamZoomScale: CGFloat = 1
    @State private var zoomScaleBeforeInputBar: CGFloat?
    @State private var followsCursorWhenZoomed = true
    @State private var pansViewportWithTwoFingers = false
    @State private var networkPathObserver = NetworkPathObserver()
    @State private var externalDisplayCoordinator = ExternalDisplayCoordinator.shared
    @State private var inputFocused = false
    @State private var externalKeyboardFocused = true
    @State private var areBottomControlsCollapsed = false
    @State private var didRecordFreeSessionStart = false
    @State private var didRecordFreeSessionLimit = false

    private let freeSessionDurationInterval: TimeInterval = 60

    init(session: Session,
         preferences: Binding<SessionPreferences>,
         sessionTitle: String,
         glassyStream: GlassyStreamSessionController? = nil) {
        self.session = session
        _preferences = preferences
        self.sessionTitle = sessionTitle
        self.glassyStream = glassyStream

        let preferences = preferences.wrappedValue.normalized
        _streamZoomScale = State(initialValue: CGFloat(preferences.zoomScale))
        _followsCursorWhenZoomed = State(initialValue: preferences.followsCursor)
        _pansViewportWithTwoFingers = State(
            initialValue: preferences.pansViewportWithTwoFingers
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
        }
        .overlay(alignment: .topTrailing) {
            if session.status == .connected {
                controlPill
            }
        }
        .overlay(alignment: .topLeading) {
            if isConnectedFreeSession, let freeSessionEndDate {
                FreeSessionTimerPill(endDate: freeSessionEndDate,
                                     action: presentFreeSessionTimerInfo)
                    .padding(.top, 20)
                    .padding(.leading, 20)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsInputBar && session.status == .connected && !isExternalControllerActive {
                inputBar
            }
        }
        .overlay(alignment: .bottom) {
            if session.status == .connected,
               !showsInputBar,
               !isExternalControllerActive {
                sessionBottomControls
                    .padding(.horizontal, horizontalSizeClass == .compact ? 4 : 20)
                    .padding(.bottom, 28)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isSessionPaywallPresented,
               onDismiss: handleSessionPaywallDismissed) {
            RevenueCatPaywallSheet(
                source: sessionPaywallSource,
                onProAccessGranted: handleSessionProAccessGranted
            )
        }
        .sheet(isPresented: $isFreeSessionTimerInfoPresented,
               onDismiss: handleFreeSessionTimerInfoDismissed) {
            FreeSessionTimerSheet(endDate: freeSessionEndDate,
                                  purchase: purchaseFromFreeSessionTimerInfo)
        }
        .onAppear {
            networkPathObserver.start()
            if glassyStream != nil {
                deactivateExternalControllerIfNeeded()
            }
            logDisplayControlState(reason: "sessionViewAppeared")
        }
        .onDisappear {
            networkPathObserver.stop()
            deactivateExternalControllerIfNeeded()
        }
        .onChange(of: networkPathObserver.snapshot?.status, initial: true) { _, pathStatus in
            guard let pathStatus else { return }
            session.updateNetworkPathStatus(pathStatus)
        }
        .onChange(of: session.status) { _, _ in
            logDisplayControlState(reason: "statusChanged")
            if session.status != .connected {
                releaseHeldModifierKeys()
            }

            if case .disconnected = session.status {
                deactivateExternalControllerIfNeeded()
            }
        }
        .onChange(of: session.displays) { _, _ in
            logDisplayControlState(reason: "displayLayoutChanged")
        }
        .onChange(of: session.displaySelection) { _, selection in
            logDisplayControlState(reason: "displaySelectionChanged")
            updatePreference(\.displaySelection, to: selection)
        }
        .onChange(of: session.touchMode) { _, touchMode in
            updatePreference(\.touchMode, to: touchMode)
        }
        .onChange(of: session.preferredFrameRate) { _, frameRate in
            updatePreference(\.frameRate, to: frameRate)
        }
        .onChange(of: session.quality) { _, quality in
            updatePreference(\.quality, to: quality)
        }
        .onChange(of: streamZoomScale) { _, zoomScale in
            guard !showsInputBar else { return }
            updatePreference(\.zoomScale, to: Double(zoomScale))
        }
        .onChange(of: followsCursorWhenZoomed) { _, followsCursor in
            updatePreference(\.followsCursor, to: followsCursor)
        }
        .onChange(of: pansViewportWithTwoFingers) { _, pansViewport in
            updatePreference(\.pansViewportWithTwoFingers, to: pansViewport)
        }
        .onChange(of: showsInputBar) { _, _ in
            logDisplayControlState(reason: "inputBarVisibilityChanged")
        }
        .onChange(of: subscriptionStore.hasProAccess) { _, hasProAccess in
            if hasProAccess {
                handleSessionProAccessGranted()
                freeSessionEndDate = nil
            }
        }
        .task(id: isFreeSessionLifecycleActive) {
            await enforceFreeSessionLimitIfNeeded()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch session.status {
        case .idle, .connecting:
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)

                Text("Connecting…")
                    .foregroundStyle(.secondary)

                Button("Cancel") {
                    AppLog.ui.info("Connection cancel button tapped")
                    session.disconnect()
                    dismiss()
                }
                .buttonStyle(.glass)
            }

        case .connected:
            if isExternalControllerActive {
                ExternalSessionControllerView(session: session,
                                              sessionTitle: sessionTitle,
                                              heldModifierKeys: $heldModifierKeys,
                                              isKeyboardFocused: $externalKeyboardFocused,
                                              stopControllerMode: deactivateExternalControllerIfNeeded)
            } else {
                SessionRemoteContent(session: session,
                                     reconnectState: nil,
                                     zoomScale: $streamZoomScale,
                                     followsCursor: followsCursorWhenZoomed,
                                     pansViewportWithTwoFingers: pansViewportWithTwoFingers,
                                     keyboardAvoidanceActive: showsInputBar,
                                     showsTrackpadCursorDot: preferences.showsTrackpadCursorDot,
                                     acceptsHardwareKeyboardInput: acceptsRemoteHardwareKeyboardInput,
                                     glassyStream: glassyStream)
            }

        case .reconnecting(let reconnectState):
            SessionRemoteContent(session: session,
                                 reconnectState: reconnectState,
                                 zoomScale: $streamZoomScale,
                                 followsCursor: followsCursorWhenZoomed,
                                 pansViewportWithTwoFingers: pansViewportWithTwoFingers,
                                 showsTrackpadCursorDot: preferences.showsTrackpadCursorDot,
                                 acceptsHardwareKeyboardInput: false,
                                 glassyStream: glassyStream)

        case .disconnected(let message):
            VStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text("Disconnected")
                    .font(.title3.weight(.semibold))

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                HStack(spacing: 12) {
                    Button("Close") {
                        AppLog.ui.info("Disconnected session close button tapped")
                        dismiss()
                    }
                    .buttonStyle(.glass)

                    Button("Reconnect") {
                        AppLog.ui.info("Reconnect button tapped")
                        session.retryConnect()
                    }
                    .buttonStyle(.glassProminent)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Floating controls

    @ViewBuilder
    private var sessionBottomControls: some View {
        HStack(spacing: 0) {
            sessionControlsVisibilityButton

            if !areBottomControlsCollapsed {
                ViewThatFits(in: .horizontal) {
                    sessionBottomControlContent(showsDisplayMenu: true,
                                                showsResetZoom: true,
                                                showsZoomModes: true)
                    sessionBottomControlContent(showsDisplayMenu: false,
                                                showsResetZoom: true,
                                                showsZoomModes: true)
                    sessionBottomControlContent(showsDisplayMenu: false,
                                                showsResetZoom: false,
                                                showsZoomModes: true)
                    sessionBottomControlContent(showsDisplayMenu: false,
                                                showsResetZoom: false,
                                                showsZoomModes: false)
                }
                .transition(sessionControlsTransition)
            }
        }
        .padding(2)
        .liquidGlass(in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionBottomControlContent(
        showsDisplayMenu: Bool,
        showsResetZoom: Bool,
        showsZoomModes: Bool
    ) -> some View {
        HStack(spacing: 0) {
            sessionZoomControls(showsResetZoom: showsResetZoom,
                                showsZoomModes: showsZoomModes)

            sessionMenuControls(showsDisplayMenu: showsDisplayMenu,
                                includesResetZoom: !showsResetZoom,
                                includesZoomModes: !showsZoomModes)
        }
    }

    private func sessionZoomControls(
        showsResetZoom: Bool,
        showsZoomModes: Bool
    ) -> some View {
        SessionZoomControls(zoomScale: $streamZoomScale,
                            followsCursor: $followsCursorWhenZoomed,
                            pansViewportWithTwoFingers: $pansViewportWithTwoFingers,
                            showsResetZoom: showsResetZoom,
                            showsZoomModes: showsZoomModes)
    }

    private func sessionMenuControls(
        showsDisplayMenu: Bool,
        includesResetZoom: Bool,
        includesZoomModes: Bool
    ) -> some View {
        HStack(spacing: 0) {
            if showsDisplayMenu,
               glassyStream == nil,
               session.displayOptions.count > 1 {
                SessionDisplayMenu(session: session)
            }

            SessionOptionsMenu(session: session,
                               sessionTitle: sessionTitle,
                               externalDisplayCoordinator: externalDisplayCoordinator,
                               showsTrackpadCursorDot: $preferences.showsTrackpadCursorDot,
                               zoomScale: $streamZoomScale,
                               followsCursor: $followsCursorWhenZoomed,
                               pansViewportWithTwoFingers: $pansViewportWithTwoFingers,
                               usesGlassyStream: glassyStream != nil,
                               includesDisplayPicker: !showsDisplayMenu,
                               includesResetZoom: includesResetZoom,
                               includesZoomModes: includesZoomModes)
        }
    }

    private var sessionControlsVisibilityButton: some View {
        Button(action: toggleBottomControls) {
            Image(systemName: "chevron.right")
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .rotationEffect(.degrees(areBottomControlsCollapsed ? 0 : 180))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(
            areBottomControlsCollapsed
                ? "Expand session controls"
                : "Collapse session controls"
        )
        .accessibilityValue(areBottomControlsCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(
            areBottomControlsCollapsed
                ? "Shows zoom, display, and session options."
                : "Hides zoom, display, and session options."
        )
        .accessibilityIdentifier("session.controls.toggle")
        .help(
            areBottomControlsCollapsed
                ? "Expand session controls"
                : "Collapse session controls"
        )
    }

    private var controlPill: some View {
        HStack(spacing: 2) {
            if session.supportsClipboardPaste {
                PasteButton(payloadType: String.self) { strings in
                    session.pasteText(strings.joined(separator: "\n"))
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Paste to Mac")
                .accessibilityHint("Pastes copied text into the active app on your Mac.")
                .help("Paste to Mac")
                .padding(.leading, 8)
            }

            if isExternalControllerActive {
                Button(externalKeyboardFocused ? "Hide Software Keyboard" : "Show Software Keyboard",
                       systemImage: externalKeyboardFocused ? "keyboard.chevron.compact.down" : "keyboard",
                       action: toggleExternalKeyboard)
                    .labelStyle(.iconOnly)
                    .padding(12)
                    .contentShape(Rectangle())
            } else {
                Button("Toggle Software Keyboard", systemImage: "keyboard", action: toggleInputBar)
                    .labelStyle(.iconOnly)
                    .padding(12)
                    .contentShape(Rectangle())
            }

            Button("Close Session", systemImage: "xmark", action: closeSession)
                .labelStyle(.iconOnly)
                .padding(12)
                .contentShape(Rectangle())
        }
        .font(.body.weight(.medium))
        .foregroundStyle(.white)
        .liquidGlass(in: Capsule())
        .padding(.top, 20)
        .padding(.trailing, 20)
        .alert("Couldn't Paste", isPresented: Binding(
            get: { session.clipboardPasteError != nil },
            set: { if !$0 { session.clearClipboardPasteError() } }
        )) {
            Button("OK") { session.clearClipboardPasteError() }
        } message: {
            Text(session.clipboardPasteError ?? "")
        }
    }

    private var isConnectedFreeSession: Bool {
        session.status == .connected && !subscriptionStore.hasProAccess
    }

    private var isFreeSessionLifecycleActive: Bool {
        guard !subscriptionStore.hasProAccess else { return false }

        switch session.status {
        case .connected, .reconnecting:
            return true
        case .connecting:
            return freeSessionEndDate != nil
        case .idle, .disconnected:
            return false
        }
    }

    private var freeSessionHasExpired: Bool {
        guard let freeSessionEndDate else { return false }
        return freeSessionEndDate <= Date.now
    }

    private var acceptsRemoteHardwareKeyboardInput: Bool {
        session.status == .connected
            && !showsInputBar
            && !isSessionPaywallPresented
            && !isFreeSessionTimerInfoPresented
    }

    private var isExternalControllerActive: Bool {
        guard glassyStream == nil else { return false }
        guard let vncSession = session as? VNCSession else { return false }
        return externalDisplayCoordinator.isControllerModeEnabled(for: vncSession)
    }

    private func logDisplayControlState(reason: String) {
        let displayCount = session.displays.count
        let bottomControlsVisible = session.status == .connected
            && !showsInputBar
            && !isExternalControllerActive
        let displayOptionCount = session.displayOptions.count
        let displayControlVisible = bottomControlsVisible
            && !areBottomControlsCollapsed
            && displayOptionCount > 1
        let optionDescription = session.displayOptions.map(\.logDescription).joined(separator: "; ")
        let layoutDescription = session.displays.isEmpty
            ? "none"
            : session.displays.map(\.logDescription).joined(separator: "; ")

        AppLog.ui.info("Session display controls state; reason=\(reason, privacy: .public) status=\(self.session.status.logDescription, privacy: .public) displayCount=\(displayCount, privacy: .public) selection=\(self.session.displaySelection.logDescription, privacy: .public) bottomControlsVisible=\(bottomControlsVisible, privacy: .public) bottomControlsCollapsed=\(self.areBottomControlsCollapsed, privacy: .public) displayControlVisible=\(displayControlVisible, privacy: .public) displayOptionCount=\(displayOptionCount, privacy: .public) displayOptions=\(optionDescription, privacy: .public) inputBarVisible=\(self.showsInputBar, privacy: .public) layout=\(layoutDescription, privacy: .public)")
    }

    private var sessionControlsTransition: AnyTransition {
        guard !accessibilityReduceMotion else { return .opacity }

        return .opacity.combined(with: .scale(scale: 0.98, anchor: .leading))
    }

    private func updatePreference<Value: Equatable>(
        _ keyPath: WritableKeyPath<SessionPreferences, Value>,
        to value: Value
    ) {
        guard preferences[keyPath: keyPath] != value else { return }

        var updatedPreferences = preferences
        updatedPreferences[keyPath: keyPath] = value
        preferences = updatedPreferences.normalized
    }

    private func enforceFreeSessionLimitIfNeeded() async {
        guard isFreeSessionLifecycleActive else {
            freeSessionEndDate = nil
            return
        }

        if freeSessionEndDate == nil {
            freeSessionEndDate = Date.now.addingTimeInterval(freeSessionDurationInterval)
            recordFreeSessionStartIfNeeded()
        }

        guard let freeSessionEndDate else { return }
        let remainingDuration = max(0, freeSessionEndDate.timeIntervalSinceNow)

        try? await Task.sleep(for: .seconds(remainingDuration))

        guard !Task.isCancelled else { return }

        while isFreeSessionLifecycleActive {
            if session.status == .connected {
                AppLog.subscriptions.info("Free session limit reached; presenting paywall")
                recordFreeSessionLimitIfNeeded()
                presentSessionPaywall(
                    endsSessionOnDismiss: true,
                    source: .sessionLimit
                )
                return
            }

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
        }
    }

    private func handleSessionProAccessGranted() {
        guard isSessionPaywallPresented else { return }

        AppLog.subscriptions.info("Pro access granted from session paywall; keeping remote session active")
        shouldEndSessionOnPaywallDismiss = false
        isSessionPaywallPresented = false
        freeSessionEndDate = nil
    }

    private func handleSessionPaywallDismissed() {
        let shouldEndSession = shouldEndSessionOnPaywallDismiss
        shouldEndSessionOnPaywallDismiss = false

        Task {
            await subscriptionStore.refresh()

            guard shouldEndSession else { return }
            guard session.status == .connected else { return }
            guard !subscriptionStore.hasProAccess else { return }

            AppLog.subscriptions.info("Session paywall dismissed without Pro access; ending remote session")
            releaseHeldModifierKeys()
            session.disconnect()
            dismiss()
        }
    }

    private func presentFreeSessionTimerInfo() {
        guard isConnectedFreeSession else { return }

        AppLog.subscriptions.info("Free session timer tapped")
        analytics.track(
            .freeSessionTimerOpened,
            context: AnalyticsEventContext(source: .freeSessionTimer)
        )
        isFreeSessionTimerInfoPresented = true
    }

    private func purchaseFromFreeSessionTimerInfo() {
        AppLog.subscriptions.info("Free session timer purchase button tapped")
        funnelMilestones.record(.freeTimerUpgradeTapped)
        presentSessionPaywall(
            endsSessionOnDismiss: freeSessionHasExpired,
            source: .freeSessionTimer
        )
    }

    private func handleFreeSessionTimerInfoDismissed() {
        guard opensPaywallAfterFreeSessionInfoDismissal else { return }

        opensPaywallAfterFreeSessionInfoDismissal = false
        let endsSessionOnDismiss = pendingPaywallEndsSessionOnDismiss
        pendingPaywallEndsSessionOnDismiss = false
        presentSessionPaywall(
            endsSessionOnDismiss: endsSessionOnDismiss,
            source: sessionPaywallSource
        )
    }

    private func presentSessionPaywall(
        endsSessionOnDismiss: Bool,
        source: PaywallSource
    ) {
        releaseHeldModifierKeys()
        sessionPaywallSource = source

        if isSessionPaywallPresented {
            shouldEndSessionOnPaywallDismiss = shouldEndSessionOnPaywallDismiss || endsSessionOnDismiss
            return
        }

        if isFreeSessionTimerInfoPresented {
            pendingPaywallEndsSessionOnDismiss = endsSessionOnDismiss
            opensPaywallAfterFreeSessionInfoDismissal = true
            isFreeSessionTimerInfoPresented = false
            return
        }

        shouldEndSessionOnPaywallDismiss = endsSessionOnDismiss
        isSessionPaywallPresented = true
    }

    private func recordFreeSessionStartIfNeeded() {
        guard !didRecordFreeSessionStart else { return }
        didRecordFreeSessionStart = true

        let startKind = funnelMilestones.recordFreeSessionStarted()
        analytics.track(
            .freeSessionStarted,
            context: AnalyticsEventContext(source: .app, outcome: .success)
        )

        switch startKind {
        case .first:
            break
        case .returning:
            analytics.track(.freeSessionRestarted)
        case .restartedAfterLimit:
            analytics.track(.freeSessionRestarted)
            analytics.track(.freeSessionRestartedAfterLimit)
        }
    }

    private func recordFreeSessionLimitIfNeeded() {
        guard !didRecordFreeSessionLimit else { return }
        didRecordFreeSessionLimit = true

        funnelMilestones.recordFreeSessionLimitReached()
        analytics.track(
            .freeSessionLimitReached,
            context: AnalyticsEventContext(source: .sessionLimit)
        )
    }

    private func toggleInputBar() {
        if showsInputBar {
            showsInputBar = false
            if let zoomScaleBeforeInputBar {
                streamZoomScale = zoomScaleBeforeInputBar
                self.zoomScaleBeforeInputBar = nil
            }
        } else {
            zoomScaleBeforeInputBar = streamZoomScale
            showsInputBar = true
        }
        inputFocused = showsInputBar

        if !showsInputBar {
            releaseHeldModifierKeys()
        }

        AppLog.ui.info("Software input bar visibility changed; visible=\(self.showsInputBar, privacy: .public)")
    }

    private func toggleBottomControls() {
        let willCollapse = !areBottomControlsCollapsed

        withAnimation(
            accessibilityReduceMotion
                ? nil
                : .smooth(duration: 0.22)
        ) {
            areBottomControlsCollapsed = willCollapse
        }

        AppLog.ui.info("Session bottom controls changed; collapsed=\(willCollapse, privacy: .public)")
        logDisplayControlState(reason: "bottomControlsToggled")
    }

    private func toggleExternalKeyboard() {
        externalKeyboardFocused.toggle()
        AppLog.ui.info("External controller keyboard visibility changed; visible=\(self.externalKeyboardFocused, privacy: .public)")
    }

    private func closeSession() {
        AppLog.ui.info("Session close button tapped")
        releaseHeldModifierKeys()
        deactivateExternalControllerIfNeeded()
        session.disconnect()
        dismiss()
    }

    private func deactivateExternalControllerIfNeeded() {
        guard let vncSession = session as? VNCSession else { return }
        externalDisplayCoordinator.deactivate(session: vncSession)
    }

    private func releaseHeldModifierKeys() {
        guard !heldModifierKeys.isEmpty else { return }

        session.releaseHeldModifiers()
        heldModifierKeys.removeAll()
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            SessionShortcutStrip(session: session,
                                 heldModifierKeys: $heldModifierKeys) {
                inputFocused = true
            }

            HStack(spacing: 10) {
                RemoteSessionTextField("Type to send to the Mac…",
                                       text: $textToSend,
                                       isFocused: $inputFocused,
                                       onSubmit: submitSoftwareInput)

                Button("Send Return", systemImage: "return", action: sendSoftwareReturn)
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .fixedSize(horizontal: false, vertical: true)
            .liquidGlass(in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func submitSoftwareInput() {
        AppLog.ui.debug("Software input submitted; characterCount=\(self.textToSend.count, privacy: .public)")
        session.sendText(textToSend)
        textToSend = ""
        inputFocused = true
    }

    private func sendSoftwareReturn() {
        AppLog.ui.debug("Software return key tapped")
        session.sendReturn()
        inputFocused = true
    }
}
