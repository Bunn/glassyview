import Combine
import OSLog
import SwiftUI
import UIKit

private let remoteFramebufferRenderingSignposter = OSSignposter(logger: AppLog.pointsOfInterest)

/// Renders the remote framebuffer into a dirty-rect aware view and maps touches
/// to VNC pointer events.
///
/// One finger (see `RemoteTouchMode`):
/// - direct:   tap = click where you touch, drag = click-drag (absolute)
/// - trackpad: drag moves the cursor from where it is, tap = click at the
///             cursor, long-press then drag = click-drag (relative)
///
/// Two fingers (both modes):
/// - two-finger tap / trackpad secondary tap = right click
/// - two-finger drag scrolls the remote Mac by default
/// - in Pan View mode, two-finger drag pans a zoomed local viewport
/// - while the software keyboard is open, two-finger drag pans its obstructed viewport
/// - pinch = zoom the visible stream
/// Three-finger touch drag always pans a zoomed local viewport.
/// A discrete mouse wheel always scrolls the remote Mac.
///
/// When keep-cursor-visible is enabled, zoomed cursor movement leaves the
/// viewport still until the remote cursor approaches an edge, then reveals
/// only the next portion of the desktop.
struct RemoteDesktopView<Session: RemoteSessionControlling>: UIViewRepresentable {
    // Deliberately NOT @ObservedObject: frames are pushed straight to the
    // view via `framebufferUpdatePublisher` (see makeUIView), so SwiftUI never
    // needs to re-render this representable at framebuffer rate.
    let session: Session
    var selectedFramebufferFrame: CGRect?
    @Binding var zoomScale: CGFloat
    /// Keeps the fitted desktop size stable when the keyboard shortens the visible view.
    var fitsContentToWindow = false
    var followsCursor: Bool
    var pansViewportWithTwoFingers: Bool = false
    var keyboardAvoidanceActive = false
    var acceptsHardwareKeyboardInput: Bool
    var acceptsPointerInput: Bool = true
    var showsFramebuffer: Bool = true
    var showsCursorOverlay: Bool = true
    var showsTrackpadCursorDot: Bool = false
    var allowsZoom: Bool = true
    var touchModeOverride: RemoteTouchMode?
    var glassyStreamRenderer: GlassyStreamVideoRenderer?

    func makeUIView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.session = session
        view.setFitsContentToWindow(fitsContentToWindow)
        view.setAcceptsHardwareKeyboardInput(acceptsHardwareKeyboardInput)
        view.setAcceptsPointerInput(acceptsPointerInput)
        view.setShowsFramebuffer(showsFramebuffer)
        view.setShowsCursorOverlay(showsCursorOverlay)
        view.setShowsTrackpadCursorDot(showsTrackpadCursorDot)
        view.setAllowsZoom(allowsZoom)
        view.setPansViewportWithTwoFingers(pansViewportWithTwoFingers)
        view.setKeyboardAvoidanceActive(keyboardAvoidanceActive)
        view.setTouchModeOverride(touchModeOverride)
        view.setGlassyStreamRenderer(glassyStreamRenderer)
        view.onZoomScaleChanged = context.coordinator.setZoomScale(_:)
        view.setVisibleFramebufferFrame(selectedFramebufferFrame)
        view.setPreferredFrameRate(session.preferredFrameRate)

        // Frames bypass SwiftUI entirely: publisher -> UIKit drawing.
        // CurrentValueSubject replays the latest frame on subscription.
        context.coordinator.framebufferUpdateSubscription = session.framebufferUpdatePublisher
            .sink { [weak view] update in
                view?.display(framebufferUpdate: update)
            }
        context.coordinator.cursorSubscription = session.cursorPublisher
            .sink { [weak view] cursor in
                view?.display(cursor: cursor)
            }
        context.coordinator.cursorLocationSubscription = session.cursorLocationPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak view] cursorLocation in
                view?.display(cursorLocation: cursorLocation)
            }

        // First responder is claimed in didMoveToWindow, once the view is
        // actually in a key window.
        return view
    }

    func updateUIView(_ uiView: ScreenView, context: Context) {
        context.coordinator.zoomScale = $zoomScale
        uiView.session = session
        uiView.setFitsContentToWindow(fitsContentToWindow)
        uiView.setVisibleFramebufferFrame(selectedFramebufferFrame)
        uiView.setFollowsCursor(followsCursor)
        uiView.setZoomScale(zoomScale, notify: false)
        uiView.setPreferredFrameRate(session.preferredFrameRate)
        uiView.setAcceptsHardwareKeyboardInput(acceptsHardwareKeyboardInput)
        uiView.setAcceptsPointerInput(acceptsPointerInput)
        uiView.setShowsFramebuffer(showsFramebuffer)
        uiView.setShowsCursorOverlay(showsCursorOverlay)
        uiView.setShowsTrackpadCursorDot(showsTrackpadCursorDot)
        uiView.setAllowsZoom(allowsZoom)
        uiView.setPansViewportWithTwoFingers(pansViewportWithTwoFingers)
        uiView.setKeyboardAvoidanceActive(keyboardAvoidanceActive)
        uiView.setTouchModeOverride(touchModeOverride)
        uiView.setGlassyStreamRenderer(glassyStreamRenderer)
    }

    static func dismantleUIView(_ uiView: ScreenView, coordinator: Coordinator) {
        coordinator.framebufferUpdateSubscription = nil
        coordinator.cursorSubscription = nil
        coordinator.cursorLocationSubscription = nil
        uiView.prepareForDismantle()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale)
    }

    final class Coordinator {
        var zoomScale: Binding<CGFloat>
        var framebufferUpdateSubscription: AnyCancellable?
        var cursorSubscription: AnyCancellable?
        var cursorLocationSubscription: AnyCancellable?

        init(zoomScale: Binding<CGFloat>) {
            self.zoomScale = zoomScale
        }

        @MainActor
        func setZoomScale(_ zoomScale: CGFloat) {
            self.zoomScale.wrappedValue = zoomScale
        }
    }

    final class ScreenView: RemoteClipboardInputView, UIGestureRecognizerDelegate {
        weak var session: (any RemoteSessionInputControlling)?
        override var acceptsRemotePaste: Bool {
            acceptsHardwareKeyboardInput && session?.supportsClipboardPaste == true
        }

        override func sendPasteText(_ text: String) {
            session?.pasteText(text)
        }
        var onZoomScaleChanged: ((CGFloat) -> Void)?

        private var fullImageSize: CGSize = .zero
        private var selectedFramebufferFrame: CGRect?
        private let framebufferView = FramebufferImageView()
        private var glassyStreamView: GlassyStreamDisplayView?
        private let cursorLayer = CALayer()
        private let fallbackCursorLayer = CALayer()
        private var remoteCursor: RemoteCursor?
        private weak var pointerScrollPan: UIPanGestureRecognizer?
        private weak var pointerWheelScrollPan: UIPanGestureRecognizer?
        private weak var pinchGesture: UIPinchGestureRecognizer?
        private weak var touchPanGesture: UIPanGestureRecognizer?
        private var pendingFramebufferUpdate: RemoteFramebufferUpdate?
        private var framebufferFlushTask: Task<Void, Never>?
        private var lastFramebufferFlushTime: TimeInterval = 0
        private var framebufferRenderInterval = RemoteFrameRate.balanced.updateInterval
        private var keyboardFocusTask: Task<Void, Never>?
        private var zoomScaleReconciliationTask: Task<Void, Never>?
        private let hardwareKeyboardInputView = UIView(frame: .zero)
        private var acceptsHardwareKeyboardInput = true
        private var showsFramebuffer = true
        private var showsCursorOverlay = true
        private var showsTrackpadCursorDot = false
        private var allowsZoom = true
        private var pansViewportWithTwoFingers = false
        private var keyboardAvoidanceActive = false
        private var fitsContentToWindow = false
        private var touchModeOverride: RemoteTouchMode?

        private var zoomScale: CGFloat = 1
        private var followsCursor = true
        private var viewportCenter: CGPoint?
        private var manualViewportPositionActive = false
        private var pinchStartZoomScale: CGFloat = 1
        private var pinchIsActive = false
        private var pinchIsSuppressedByThreeFingerPan = false
        private var lastLocalCursorLocation: CGPoint?
        private var pendingZeroCursorFollowTask: Task<Void, Never>?

        // Single-touch state
        private var relativePointer = RelativePointerAccumulator()
        private var touchStartTime: TimeInterval = 0
        private var touchMoved = false
        private var isDragging = false
        private var multiTouchActive = false
        private var longPressTask: Task<Void, Never>?

        // Direct-mode deferred press (avoids a stray left click when the
        // first finger of a two-finger gesture lands slightly early).
        private var pendingPressTask: Task<Void, Never>?
        private var pendingPressPoint: CGPoint?
        private var directPressed = false

        // Scroll state
        private var touchScrollAccumulator = CGPoint.zero
        private var pointerScrollAccumulator = CGPoint.zero
        private var pointerWheelScrollAccumulator = CGPoint.zero
        private var touchPendingTranslation = CGPoint.zero
        private var pointerPendingTranslation = CGPoint.zero
        private var touchPanIntent: RemoteViewportGeometry.GestureIntent = .undecided
        private var pointerPanIntent: RemoteViewportGeometry.GestureIntent = .undecided

#if DEBUG
        private var lastLoggedViewportBounds: CGSize?
        private var loggedTouchPanTranslation = CGPoint.zero
        private var loggedPointerPanTranslation = CGPoint.zero
#endif

        private let tapMovementThreshold: CGFloat = 8
        private let tapDurationThreshold: TimeInterval = 0.35
        private let longPressDelay: TimeInterval = 0.5
        private let pressDebounce: TimeInterval = 0.05
        private let defaultMinimumZoomScale: CGFloat = 1
        private let maximumZoomScale: CGFloat = 4
        private let fallbackCursorDiameter: CGFloat = 12
        private let minimumTrackpadCursorLength: CGFloat = 24

        private final class FramebufferImageView: UIView {
            private var image: CGImage?
            private var fullImageSize: CGSize = .zero
            private var visibleFramebufferFrame: CGRect = .zero

            override init(frame: CGRect) {
                super.init(frame: frame)

                isOpaque = true
                backgroundColor = .black
                clipsToBounds = true
                contentMode = .redraw
                layer.magnificationFilter = .linear
                layer.minificationFilter = .linear
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func setFramebuffer(image: CGImage?,
                                imageSize: CGSize,
                                visibleFrame: CGRect) {
                self.image = image
                setFramebuffer(imageSize: imageSize,
                               visibleFrame: visibleFrame)
            }

            func setFramebuffer(imageSize: CGSize,
                                visibleFrame: CGRect) {
                fullImageSize = imageSize
                visibleFramebufferFrame = visibleFrame
            }

            override func draw(_ rect: CGRect) {
                guard let image,
                      fullImageSize.width > 0,
                      fullImageSize.height > 0,
                      visibleFramebufferFrame.width > 0,
                      visibleFramebufferFrame.height > 0,
                      bounds.width > 0,
                      bounds.height > 0 else {
                    return
                }

                guard let context = UIGraphicsGetCurrentContext() else { return }

                let signpostID = remoteFramebufferRenderingSignposter.makeSignpostID()
                let state = remoteFramebufferRenderingSignposter.beginInterval("Remote framebuffer draw", id: signpostID)
                defer {
                    remoteFramebufferRenderingSignposter.endInterval("Remote framebuffer draw", state)
                }

                let scale = bounds.width / visibleFramebufferFrame.width
                let drawRect = CGRect(x: -visibleFramebufferFrame.minX * scale,
                                      y: -visibleFramebufferFrame.minY * scale,
                                      width: fullImageSize.width * scale,
                                      height: fullImageSize.height * scale)

                context.saveGState()
                context.clip(to: rect)
                defer {
                    context.restoreGState()
                }

                context.interpolationQuality = .default

                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(image,
                             in: CGRect(x: drawRect.minX,
                                        y: bounds.height - drawRect.maxY,
                                        width: drawRect.width,
                                        height: drawRect.height))
            }
        }

        /// Points of finger travel per wheel step. Wheel steps only move a
        /// few lines each on macOS, so this needs to be small — and it acts
        /// as a sensitivity dial (lower = faster scrolling).
        private let scrollStep: CGFloat = 4

        override var canBecomeFirstResponder: Bool {
            true
        }

        /// This responder handles physical keyboard presses only. Returning an
        /// empty input view prevents UIKit from presenting the software
        /// keyboard when focus is restored around menus and other windows.
        override var inputView: UIView? {
            hardwareKeyboardInputView
        }

        /// Grabs keyboard focus for hardware-keyboard forwarding — but only
        /// while our window is key. Stealing first responder while another
        /// window is presenting (e.g. the session options menu, which iOS 26
        /// hosts in its own window) dismisses that presentation and triggers
        /// endless keyboard-geometry conversions between the two windows
        /// ("Invalid UIScreen coordinate space conversion" log spam).
        private func becomeFirstResponderIfAppropriate() {
            guard acceptsHardwareKeyboardInput,
                  let window,
                  window.isKeyWindow,
                  !isFirstResponder else {
                return
            }
            becomeFirstResponder()
        }

        func setAcceptsHardwareKeyboardInput(_ accepts: Bool) {
            guard acceptsHardwareKeyboardInput != accepts else { return }

            acceptsHardwareKeyboardInput = accepts

            if accepts {
                requestKeyboardFocus()
            } else {
                requestKeyboardBlur()
            }
        }

        func setAcceptsPointerInput(_ accepts: Bool) {
            isUserInteractionEnabled = accepts
        }

        func setShowsFramebuffer(_ showsFramebuffer: Bool) {
            guard self.showsFramebuffer != showsFramebuffer else { return }

            self.showsFramebuffer = showsFramebuffer
            backgroundColor = showsFramebuffer ? .black : .clear
            framebufferView.isHidden = !showsFramebuffer
            updateCursorLayerFrame()
        }

        func setShowsCursorOverlay(_ showsCursorOverlay: Bool) {
            guard self.showsCursorOverlay != showsCursorOverlay else { return }

            self.showsCursorOverlay = showsCursorOverlay
            updateCursorLayerFrame()
        }

        func setShowsTrackpadCursorDot(_ showsTrackpadCursorDot: Bool) {
            guard self.showsTrackpadCursorDot != showsTrackpadCursorDot else { return }

            self.showsTrackpadCursorDot = showsTrackpadCursorDot
            updateCursorLayerFrame()
        }

        func setAllowsZoom(_ allowsZoom: Bool) {
            guard self.allowsZoom != allowsZoom else { return }

            self.allowsZoom = allowsZoom
            if !allowsZoom {
                setZoomScale(minimumZoomScale, anchorInView: nil, notify: true)
            }
        }

        func setPansViewportWithTwoFingers(_ enabled: Bool) {
            guard pansViewportWithTwoFingers != enabled else { return }

            pansViewportWithTwoFingers = enabled
            logViewport("Pan View setting changed; enabled=\(enabled)")
        }

        func setKeyboardAvoidanceActive(_ active: Bool) {
            guard keyboardAvoidanceActive != active else { return }

            keyboardAvoidanceActive = active
            logViewport("Keyboard avoidance changed; active=\(active)")
        }

        func setFitsContentToWindow(_ enabled: Bool) {
            guard fitsContentToWindow != enabled else { return }

            fitsContentToWindow = enabled
            updateFramebufferViewFrame()
        }

        func setTouchModeOverride(_ touchMode: RemoteTouchMode?) {
            touchModeOverride = touchMode
            updateCursorLayerFrame()
        }

        private func requestKeyboardFocus() {
            guard acceptsHardwareKeyboardInput, window != nil else { return }

            keyboardFocusTask?.cancel()
            keyboardFocusTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }

                self?.keyboardFocusTask = nil
                self?.becomeFirstResponderIfAppropriate()
            }
        }

        /// Resigning first responder can ask the hosting view for its next
        /// responder. Defer that query until after SwiftUI finishes the current
        /// representable update to avoid re-entering its AttributeGraph.
        private func requestKeyboardBlur() {
            keyboardFocusTask?.cancel()

            guard isFirstResponder else {
                keyboardFocusTask = nil
                return
            }

            keyboardFocusTask = Task { @MainActor [weak self] in
                await Task.yield()

                guard let self else { return }
                self.keyboardFocusTask = nil

                guard !Task.isCancelled,
                      !self.acceptsHardwareKeyboardInput,
                      self.isFirstResponder else {
                    return
                }

                self.resignFirstResponder()
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)

            backgroundColor = .black
            clipsToBounds = true
            addSubview(framebufferView)

            cursorLayer.contentsGravity = .resize
            cursorLayer.magnificationFilter = .nearest
            cursorLayer.minificationFilter = .nearest
            cursorLayer.isHidden = true
            layer.addSublayer(cursorLayer)

            fallbackCursorLayer.backgroundColor = UIColor.white.cgColor
            fallbackCursorLayer.borderColor = UIColor.black.cgColor
            fallbackCursorLayer.borderWidth = 2
            fallbackCursorLayer.cornerRadius = fallbackCursorDiameter / 2
            fallbackCursorLayer.shadowColor = UIColor.black.cgColor
            fallbackCursorLayer.shadowOpacity = 0.65
            fallbackCursorLayer.shadowRadius = 2
            fallbackCursorLayer.shadowOffset = .zero
            fallbackCursorLayer.isHidden = true
            layer.addSublayer(fallbackCursorLayer)
            isMultipleTouchEnabled = true

            let pinch = UIPinchGestureRecognizer(target: self,
                                                 action: #selector(handlePinch(_:)))
            pinch.delegate = self
            addGestureRecognizer(pinch)
            pinchGesture = pinch

            let twoFingerTap = UITapGestureRecognizer(target: self,
                                                      action: #selector(handleTwoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2
            addGestureRecognizer(twoFingerTap)

            let pointerSecondaryTap = UITapGestureRecognizer(target: self,
                                                             action: #selector(handlePointerSecondaryTap(_:)))
            pointerSecondaryTap.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
            ]
            pointerSecondaryTap.buttonMaskRequired = .secondary
            addGestureRecognizer(pointerSecondaryTap)

            let touchPan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleTouchPan(_:))
            )
            touchPan.minimumNumberOfTouches = 2
            touchPan.maximumNumberOfTouches = 3
            touchPan.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue)
            ]
            touchPan.delegate = self
            addGestureRecognizer(touchPan)
            touchPanGesture = touchPan

            let pointerHover = UIHoverGestureRecognizer(target: self,
                                                        action: #selector(handlePointerHover(_:)))
            addGestureRecognizer(pointerHover)

            let pointerScrollPan = UIPanGestureRecognizer(target: self,
                                                          action: #selector(handlePointerScroll(_:)))
            // UIKit identifies trackpads as continuous scroll sources.
            pointerScrollPan.allowedScrollTypesMask = .continuous
            pointerScrollPan.delegate = self
            addGestureRecognizer(pointerScrollPan)
            self.pointerScrollPan = pointerScrollPan

            let pointerWheelScrollPan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handlePointerWheelScroll(_:))
            )
            // Keep a physical mouse wheel mapped to the remote machine even
            // while a two-finger trackpad drag is panning the local viewport.
            pointerWheelScrollPan.allowedScrollTypesMask = .discrete
            pointerWheelScrollPan.delegate = self
            addGestureRecognizer(pointerWheelScrollPan)
            self.pointerWheelScrollPan = pointerWheelScrollPan
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            let zoomWasReconciled = reconcileZoomScaleWithMinimumIfNeeded()
            guard !zoomWasReconciled else {
                logViewportBoundsChangeIfNeeded(reason: "zoom reconciled")
                return
            }

            updateFramebufferViewFrame()
            revealCursorIfNeeded(requiresOutwardMovement: false)
            logViewportBoundsChangeIfNeeded(reason: "layout completed")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()

            updateFramebufferViewFrame()

            registerKeyWindowObservers()

            if window != nil {
                requestKeyboardFocus()
            } else {
                keyboardFocusTask?.cancel()
                keyboardFocusTask = nil
            }
        }

        // MARK: - Key-window tracking
        //
        // While another window is key (e.g. the session options menu, which
        // iOS 26 hosts in its own window), holding first responder makes the
        // input system track keyboard geometry across both windows. Let go of
        // keyboard focus when our window resigns key. Do not automatically
        // reclaim it on didBecomeKey: menu presentation can briefly make this
        // window key again while the menu is still visible, which summons the
        // software keyboard. Direct remote interaction reclaims focus instead.

        private final class NotificationObserver: @unchecked Sendable {
            private let token: NSObjectProtocol

            init(_ token: NSObjectProtocol) {
                self.token = token
            }

            deinit {
                NotificationCenter.default.removeObserver(token)
            }
        }

        private var keyWindowObservers: [NotificationObserver] = []

        private func registerKeyWindowObservers() {
            unregisterKeyWindowObservers()

            guard let window else { return }

            let center = NotificationCenter.default

            keyWindowObservers = [
                NotificationObserver(
                    center.addObserver(forName: UIWindow.didResignKeyNotification,
                                       object: window,
                                       queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.keyboardFocusTask?.cancel()
                            self?.keyboardFocusTask = nil
                            _ = self?.resignFirstResponder()
                        }
                    }
                )
            ]
        }

        private func unregisterKeyWindowObservers() {
            keyWindowObservers.removeAll()
        }

        deinit {
            framebufferFlushTask?.cancel()
            keyboardFocusTask?.cancel()
            zoomScaleReconciliationTask?.cancel()
            pendingZeroCursorFollowTask?.cancel()
        }

        func prepareForDismantle() {
            zoomScaleReconciliationTask?.cancel()
            zoomScaleReconciliationTask = nil
            pendingZeroCursorFollowTask?.cancel()
            pendingZeroCursorFollowTask = nil
            setGlassyStreamRenderer(nil)
        }

        func setGlassyStreamRenderer(_ renderer: GlassyStreamVideoRenderer?) {
            guard let renderer else {
                glassyStreamView?.detachRenderer()
                glassyStreamView?.removeFromSuperview()
                glassyStreamView = nil
                return
            }

            let videoView: GlassyStreamDisplayView
            if let glassyStreamView {
                videoView = glassyStreamView
            } else {
                videoView = GlassyStreamDisplayView()
                videoView.isUserInteractionEnabled = false
                insertSubview(videoView, belowSubview: framebufferView)
                glassyStreamView = videoView
            }

            videoView.attach(renderer)
            videoView.frame = framebufferView.frame
        }

        func display(framebufferUpdate update: RemoteFramebufferUpdate) {
            enqueueFramebufferUpdate(update)
        }

        private func enqueueFramebufferUpdate(_ update: RemoteFramebufferUpdate) {
            let imageSizeChanged = update.imageSize != fullImageSize
            let shouldApplyImmediately = update.image == nil
                || imageSizeChanged
                || fullImageSize == .zero

            guard !shouldApplyImmediately else {
                framebufferFlushTask?.cancel()
                framebufferFlushTask = nil
                pendingFramebufferUpdate = nil
                applyFramebufferUpdate(update)
                return
            }

            let coalescedDirtyRect: CGRect?
            if let pendingFramebufferUpdate {
                if let pendingDirtyRect = pendingFramebufferUpdate.dirtyRect,
                   let updateDirtyRect = update.dirtyRect {
                    coalescedDirtyRect = pendingDirtyRect.union(updateDirtyRect)
                } else {
                    coalescedDirtyRect = nil
                }
            } else {
                coalescedDirtyRect = update.dirtyRect
            }

            pendingFramebufferUpdate = RemoteFramebufferUpdate(image: update.image,
                                                              imageSize: update.imageSize,
                                                              dirtyRect: coalescedDirtyRect)
            scheduleFramebufferFlush()
        }

        private func scheduleFramebufferFlush() {
            guard framebufferFlushTask == nil else { return }

            let elapsed = CACurrentMediaTime() - lastFramebufferFlushTime
            guard elapsed < framebufferRenderInterval else {
                flushPendingFramebufferUpdate()
                return
            }

            let delay = framebufferRenderInterval - elapsed
            let delayMilliseconds = Int64(max(1, (delay * 1000).rounded(.up)))

            framebufferFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                guard !Task.isCancelled else { return }

                self?.framebufferFlushTask = nil
                self?.flushPendingFramebufferUpdate()
            }
        }

        private func flushPendingFramebufferUpdate() {
            framebufferFlushTask?.cancel()
            framebufferFlushTask = nil

            guard let update = pendingFramebufferUpdate else { return }

            pendingFramebufferUpdate = nil
            applyFramebufferUpdate(update)
        }

        private func applyFramebufferUpdate(_ update: RemoteFramebufferUpdate) {
            let previousImageSize = imageSize

            fullImageSize = update.image == nil ? .zero : update.imageSize
            if fullImageSize == .zero {
                pendingZeroCursorFollowTask?.cancel()
                pendingZeroCursorFollowTask = nil
            }

            framebufferView.setFramebuffer(image: update.image,
                                           imageSize: fullImageSize,
                                           visibleFrame: visibleFramebufferFrame)

            let imageSizeChanged = imageSize != previousImageSize

            if imageSizeChanged || viewportCenter == nil {
                resetViewportCenter()
                lastLocalCursorLocation = localCursorLocation()
                AppLog.ui.info("Remote desktop image size changed; fullImageSize=\(Self.sizeDescription(self.fullImageSize), privacy: .public) selectedFramebufferFrame=\(Self.rectDescription(self.selectedFramebufferFrame), privacy: .public) visibleFramebufferFrame=\(Self.rectDescription(self.visibleFramebufferFrame), privacy: .public)")
            }

            updateFramebufferViewFrame()
            invalidateFramebuffer(dirtyRect: imageSizeChanged ? nil : update.dirtyRect)
            lastFramebufferFlushTime = CACurrentMediaTime()
        }

        func display(cursor: RemoteCursor?) {
            remoteCursor = cursor
            cursorLayer.contents = cursor?.image
            updateCursorLayerFrame()
        }

        func display(cursorLocation: CGPoint) {
            guard cursorLocation.x.isFinite, cursorLocation.y.isFinite else {
                return
            }

            pendingZeroCursorFollowTask?.cancel()
            pendingZeroCursorFollowTask = nil

            // Both session implementations use `.zero` while clearing their
            // geometry. Defer that one coordinate by a run-loop turn so the
            // matching empty framebuffer can cancel it. A genuine cursor at
            // the top-left is still followed once valid content remains.
            guard cursorLocation == .zero else {
                guard session?.cursorLocation == cursorLocation else { return }
                cursorLocationDidChange()
                return
            }

            pendingZeroCursorFollowTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }

                self.pendingZeroCursorFollowTask = nil
                guard self.session?.cursorLocation == cursorLocation else {
                    return
                }
                self.cursorLocationDidChange()
            }
        }

        func setVisibleFramebufferFrame(_ frame: CGRect?) {
            flushPendingFramebufferUpdate()

            let previousVisibleFrame = visibleFramebufferFrame
            let previousSelectedFrame = selectedFramebufferFrame
            selectedFramebufferFrame = frame

            updateFramebufferViewSource()

            let visibleFrame = visibleFramebufferFrame

            if visibleFrame != previousVisibleFrame {
                resetViewportCenter()
                lastLocalCursorLocation = localCursorLocation()
                updateFramebufferViewFrame()
                framebufferView.setNeedsDisplay()
            } else {
                updateCursorLayerFrame()
            }

            if selectedFramebufferFrame != previousSelectedFrame || visibleFrame != previousVisibleFrame {
                AppLog.ui.info("Remote desktop visible framebuffer changed; selectedFramebufferFrame=\(Self.rectDescription(self.selectedFramebufferFrame), privacy: .public) visibleFramebufferFrame=\(Self.rectDescription(visibleFrame), privacy: .public) fullImageSize=\(Self.sizeDescription(self.fullImageSize), privacy: .public)")
            }
        }

        func setZoomScale(_ newZoomScale: CGFloat, notify: Bool) {
            let clamped = clampedZoomScale(newZoomScale)
            guard clamped != zoomScale else { return }

            let anchor = CGPoint(x: bounds.midX, y: bounds.midY)
            setZoomScale(clamped, anchorInView: anchor, notify: notify)
        }

        func setFollowsCursor(_ newValue: Bool) {
            let changed = followsCursor != newValue
            followsCursor = newValue

            if changed {
                manualViewportPositionActive = false
                lastLocalCursorLocation = localCursorLocation()
                revealCursorIfNeeded(requiresOutwardMovement: false)
            }
        }

        func setPreferredFrameRate(_ frameRate: RemoteFrameRate) {
            let newInterval = frameRate.updateInterval
            guard newInterval != framebufferRenderInterval else { return }

            framebufferRenderInterval = newInterval

            if pendingFramebufferUpdate != nil {
                framebufferFlushTask?.cancel()
                framebufferFlushTask = nil
                scheduleFramebufferFlush()
            }
        }

        private static func rectDescription(_ rect: CGRect?) -> String {
            guard let rect else { return "nil" }

            return "x:\(rounded(rect.minX)),y:\(rounded(rect.minY)),w:\(rounded(rect.width)),h:\(rounded(rect.height))"
        }

        private static func sizeDescription(_ size: CGSize) -> String {
            "w:\(rounded(size.width)),h:\(rounded(size.height))"
        }

        private static func pointDescription(_ point: CGPoint?) -> String {
            guard let point else { return "nil" }

            return "x:\(rounded(point.x)),y:\(rounded(point.y))"
        }

        private static func gestureStateDescription(_ state: UIGestureRecognizer.State) -> String {
            switch state {
            case .possible: "possible"
            case .began: "began"
            case .changed: "changed"
            case .ended: "ended"
            case .cancelled: "cancelled"
            case .failed: "failed"
            @unknown default: "unknown"
            }
        }

        private static func gestureIntentDescription(
            _ intent: RemoteViewportGeometry.GestureIntent
        ) -> String {
            switch intent {
            case .undecided: "undecided"
            case .viewportPan: "viewportPan"
            case .remoteScroll: "remoteScroll"
            }
        }

        private static func rounded(_ value: CGFloat) -> Double {
            Double((value * 1000).rounded() / 1000)
        }

        private var loggedTouchPanTranslationForDiagnostics: CGPoint {
#if DEBUG
            loggedTouchPanTranslation
#else
            .zero
#endif
        }

        private var loggedPointerPanTranslationForDiagnostics: CGPoint {
#if DEBUG
            loggedPointerPanTranslation
#else
            .zero
#endif
        }

        private func logViewport(_ event: @autoclosure () -> String) {
#if DEBUG
            let eventDescription = event()
            let stateDescription = viewportDiagnosticState
            AppLog.input.info("[ViewportPan] \(eventDescription, privacy: .public) | \(stateDescription, privacy: .public)")
#endif
        }

        private func logViewportBoundsChangeIfNeeded(reason: String) {
#if DEBUG
            guard lastLoggedViewportBounds != bounds.size else { return }

            lastLoggedViewportBounds = bounds.size
            logViewport("Viewport bounds changed; reason=\(reason)")
#endif
        }

#if DEBUG
        private var viewportDiagnosticState: String {
            let axes = pannableViewportAxes
            let axisDescription: String

            switch (axes.contains(.horizontal), axes.contains(.vertical)) {
            case (true, true): axisDescription = "horizontal+vertical"
            case (true, false): axisDescription = "horizontal"
            case (false, true): axisDescription = "vertical"
            case (false, false): axisDescription = "none"
            }

            let visibleRect = visibleContentRectForDiagnostics
            let edgeDescription: String
            if let visibleRect {
                edgeDescription = "topHidden:\(Self.rounded(max(0, visibleRect.minY))),bottomHidden:\(Self.rounded(max(0, imageSize.height - visibleRect.maxY))),leftHidden:\(Self.rounded(max(0, visibleRect.minX))),rightHidden:\(Self.rounded(max(0, imageSize.width - visibleRect.maxX)))"
            } else {
                edgeDescription = "unavailable"
            }

            return "keyboard=\(keyboardAvoidanceActive) panView=\(pansViewportWithTwoFingers) followsCursor=\(followsCursor) manualViewport=\(manualViewportPositionActive) bounds=\(Self.sizeDescription(bounds.size)) fittingViewport=\(Self.sizeDescription(fittingViewportSize)) image=\(Self.sizeDescription(imageSize)) renderScale=\(Self.rounded(renderScale)) zoom=\(Self.rounded(zoomScale)) minimumZoom=\(Self.rounded(minimumZoomScale)) effectiveScale=\(Self.rounded(effectiveScale)) axes=\(axisDescription) center=\(Self.pointDescription(viewportCenter)) contentFrame=\(Self.rectDescription(framebufferView.frame)) visibleEdges=\(edgeDescription) cursor=\(Self.pointDescription(localCursorLocation()))"
        }

        private var visibleContentRectForDiagnostics: CGRect? {
            guard imageSize.width > 0,
                  imageSize.height > 0,
                  bounds.width > 0,
                  bounds.height > 0,
                  effectiveScale.isFinite,
                  effectiveScale > 0 else {
                return nil
            }

            let contentFrame = framebufferView.frame
            let visibleRect = CGRect(
                x: (bounds.minX - contentFrame.minX) / effectiveScale,
                y: (bounds.minY - contentFrame.minY) / effectiveScale,
                width: bounds.width / effectiveScale,
                height: bounds.height / effectiveScale
            )
            let imageRect = CGRect(origin: .zero, size: imageSize)
            let intersection = visibleRect.intersection(imageRect)

            return intersection.isNull || intersection.isEmpty ? nil : intersection
        }
#endif

        // MARK: - Coordinate mapping

        private var fullFramebufferFrame: CGRect {
            guard fullImageSize.width > 0, fullImageSize.height > 0 else {
                return .zero
            }

            return CGRect(origin: .zero, size: fullImageSize)
        }

        private var visibleFramebufferFrame: CGRect {
            let fullFrame = fullFramebufferFrame
            guard fullFrame.width > 0, fullFrame.height > 0 else {
                return .zero
            }

            guard let selectedFramebufferFrame else {
                return fullFrame
            }

            let intersection = selectedFramebufferFrame.intersection(fullFrame)

            return intersection.isNull || intersection.isEmpty ? fullFrame : intersection
        }

        private var imageSize: CGSize {
            visibleFramebufferFrame.size
        }

        private var renderScale: CGFloat {
            guard imageSize.width > 0, imageSize.height > 0,
                  fittingViewportSize.width > 0,
                  fittingViewportSize.height > 0 else { return 1 }

            return min(fittingViewportSize.width / imageSize.width,
                       fittingViewportSize.height / imageSize.height)
        }

        private var fittingViewportSize: CGSize {
            guard fitsContentToWindow, let window else { return bounds.size }
            return window.bounds.size
        }

        private var effectiveScale: CGFloat {
            renderScale * zoomScale
        }

        private func updateFramebufferViewSource() {
            framebufferView.setFramebuffer(imageSize: fullImageSize,
                                           visibleFrame: visibleFramebufferFrame)
        }

        private func invalidateFramebuffer(dirtyRect: CGRect?) {
            guard framebufferView.frame.width > 0,
                  framebufferView.frame.height > 0 else { return }

            guard let dirtyRect else {
                framebufferView.setNeedsDisplay()
                return
            }

            let visibleFrame = visibleFramebufferFrame
            let visibleDirtyRect = dirtyRect.intersection(visibleFrame)

            guard !visibleDirtyRect.isNull,
                  !visibleDirtyRect.isEmpty else { return }

            let scale = effectiveScale
            let localDirtyRect = CGRect(x: (visibleDirtyRect.minX - visibleFrame.minX) * scale,
                                        y: (visibleDirtyRect.minY - visibleFrame.minY) * scale,
                                        width: visibleDirtyRect.width * scale,
                                        height: visibleDirtyRect.height * scale)
                .integral
                .insetBy(dx: -1, dy: -1)
                .intersection(framebufferView.bounds)

            guard !localDirtyRect.isNull,
                  !localDirtyRect.isEmpty else { return }

            framebufferView.setNeedsDisplay(localDirtyRect)
        }

        private func resetViewportCenter() {
            manualViewportPositionActive = false

            guard imageSize.width > 0, imageSize.height > 0 else {
                viewportCenter = nil
                return
            }

            viewportCenter = CGPoint(x: imageSize.width / 2,
                                     y: imageSize.height / 2)
        }

        private func framebufferPoint(for point: CGPoint) -> CGPoint? {
            guard imageSize.width > 0, imageSize.height > 0,
                  bounds.width > 0, bounds.height > 0 else { return nil }

            let scale = effectiveScale
            let origin = framebufferView.frame.origin
            let visibleFrame = visibleFramebufferFrame

            let fx = (point.x - origin.x) / scale
            let fy = (point.y - origin.y) / scale

            guard fx >= 0, fy >= 0,
                  fx <= imageSize.width, fy <= imageSize.height else { return nil }

            return CGPoint(x: visibleFrame.minX + fx,
                           y: visibleFrame.minY + fy)
        }

        private func localPoint(for framebufferPoint: CGPoint) -> CGPoint? {
            let visibleFrame = visibleFramebufferFrame

            guard visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }

            let localPoint = CGPoint(x: framebufferPoint.x - visibleFrame.minX,
                                     y: framebufferPoint.y - visibleFrame.minY)

            guard localPoint.x >= 0, localPoint.y >= 0,
                  localPoint.x <= visibleFrame.width,
                  localPoint.y <= visibleFrame.height else { return nil }

            return localPoint
        }

        private func localCursorLocation() -> CGPoint? {
            guard let session else { return nil }

            return localPoint(for: session.cursorLocation)
        }

        // MARK: - Zoom

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard allowsZoom else { return }

            switch gesture.state {
            case .began:
                pinchStartZoomScale = zoomScale
                pinchIsSuppressedByThreeFingerPan =
                    (touchPanGesture?.numberOfTouches ?? 0) >= 3
                pinchIsActive = !pinchIsSuppressedByThreeFingerPan
                enterMultiTouch()
                logViewport("Pinch began; touches=\(gesture.numberOfTouches) gestureScale=\(Self.rounded(gesture.scale)) suppressed=\(pinchIsSuppressedByThreeFingerPan)")

            case .changed:
                if (touchPanGesture?.numberOfTouches ?? 0) >= 3 {
                    pinchIsSuppressedByThreeFingerPan = true
                    pinchIsActive = false
                }

                guard !pinchIsSuppressedByThreeFingerPan else { return }

                setZoomScale(pinchStartZoomScale * gesture.scale,
                             anchorInView: gesture.location(in: self),
                             notify: true)

            default:
                pinchStartZoomScale = zoomScale
                pinchIsActive = false
                pinchIsSuppressedByThreeFingerPan = false
                logViewport("Pinch ended; state=\(Self.gestureStateDescription(gesture.state)) gestureScale=\(Self.rounded(gesture.scale))")
            }
        }

        private func setZoomScale(_ newZoomScale: CGFloat,
                                  anchorInView: CGPoint?,
                                  notify: Bool) {
            zoomScaleReconciliationTask?.cancel()
            zoomScaleReconciliationTask = nil

            let clamped = clampedZoomScale(newZoomScale)
            guard imageSize.width > 0, imageSize.height > 0 else {
                zoomScale = clamped
                if notify { onZoomScaleChanged?(clamped) }
                return
            }

            let anchorFramebuffer = anchorInView.flatMap(framebufferPoint(for:))
            let anchorLocalPoint = anchorFramebuffer.flatMap(localPoint(for:))
            zoomScale = clamped

            if clamped == minimumZoomScale {
                manualViewportPositionActive = false
                viewportCenter = CGPoint(x: imageSize.width / 2,
                                         y: imageSize.height / 2)
            } else if let anchorInView, let anchorLocalPoint {
                let viewportCenterX = anchorLocalPoint.x
                    - (anchorInView.x - bounds.midX) / effectiveScale
                let viewportCenterY = anchorLocalPoint.y
                    - (anchorInView.y - bounds.midY) / effectiveScale
                viewportCenter = CGPoint(x: viewportCenterX,
                                         y: viewportCenterY)
            }

            updateFramebufferViewFrame()
            revealCursorIfNeeded(requiresOutwardMovement: false)

            if notify {
                onZoomScaleChanged?(clamped)
            }
        }

        private func clampedZoomScale(_ zoomScale: CGFloat) -> CGFloat {
            min(max(zoomScale, minimumZoomScale), maximumZoomScale)
        }

        private var minimumZoomScale: CGFloat {
            // Keyboard zoom-out is temporary and stops at the largest scale
            // that keeps the complete desktop inside the unobscured viewport.
            guard keyboardAvoidanceActive,
                  imageSize.width > 0,
                  imageSize.height > 0,
                  bounds.width > 0,
                  bounds.height > 0 else {
                return defaultMinimumZoomScale
            }

            let fittedSize = CGSize(width: imageSize.width * renderScale,
                                    height: imageSize.height * renderScale)
            guard fittedSize.width > 0, fittedSize.height > 0 else {
                return defaultMinimumZoomScale
            }

            let keyboardFitScale = min(bounds.width / fittedSize.width,
                                       bounds.height / fittedSize.height)
            return min(defaultMinimumZoomScale, keyboardFitScale)
        }

        private func reconcileZoomScaleWithMinimumIfNeeded() -> Bool {
            let reconciledScale = clampedZoomScale(zoomScale)
            guard reconciledScale != zoomScale else { return false }

            setZoomScale(reconciledScale, anchorInView: nil, notify: false)
            zoomScaleReconciliationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      self.zoomScale == reconciledScale else {
                    return
                }

                self.zoomScaleReconciliationTask = nil
                self.onZoomScaleChanged?(reconciledScale)
            }
            return true
        }

        private func updateFramebufferViewFrame() {
            guard imageSize.width > 0, imageSize.height > 0,
                  bounds.width > 0, bounds.height > 0 else {
                framebufferView.frame = .zero
                glassyStreamView?.frame = .zero
                updateCursorLayerFrame()
                return
            }

            let scale = effectiveScale
            let renderedSize = CGSize(width: imageSize.width * scale,
                                      height: imageSize.height * scale)
            if pannableViewportAxes.isEmpty {
                manualViewportPositionActive = false
            }
            let center = clampedViewportCenter(viewportCenter ?? CGPoint(x: imageSize.width / 2,
                                                                         y: imageSize.height / 2),
                                               renderedSize: renderedSize)
            viewportCenter = center

            var origin = CGPoint(x: bounds.midX - center.x * scale,
                                 y: bounds.midY - center.y * scale)

            if renderedSize.width <= bounds.width {
                origin.x = (bounds.width - renderedSize.width) / 2
            } else {
                origin.x = min(max(origin.x, bounds.width - renderedSize.width), 0)
            }

            if renderedSize.height <= bounds.height {
                origin.y = (bounds.height - renderedSize.height) / 2
            } else {
                origin.y = min(max(origin.y, bounds.height - renderedSize.height), 0)
            }

            UIView.performWithoutAnimation {
                let contentFrame = CGRect(origin: origin, size: renderedSize)
                framebufferView.frame = contentFrame
                glassyStreamView?.frame = contentFrame
            }

            updateCursorLayerFrame()
        }

        private func updateCursorLayerFrame() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            guard showsCursorOverlay,
                  let localCursor = localCursorLocation(),
                  framebufferView.frame.width > 0,
                  framebufferView.frame.height > 0 else {
                hideCursorLayers()
                return
            }

            let scale = effectiveScale
            let cursorLocation = CGPoint(
                x: framebufferView.frame.minX + localCursor.x * scale,
                y: framebufferView.frame.minY + localCursor.y * scale
            )

            if let remoteCursor = renderableRemoteCursor {
                let remoteCursorScale: CGFloat
                if effectiveTouchMode == .trackpad {
                    // A desktop-sized framebuffer can otherwise shrink the
                    // remote pointer to only a few points on iPhone.
                    let longestSide = max(remoteCursor.size.width,
                                          remoteCursor.size.height)
                    remoteCursorScale = max(
                        scale,
                        minimumTrackpadCursorLength / longestSide
                    )
                } else {
                    remoteCursorScale = scale
                }

                let cursorSize = CGSize(
                    width: remoteCursor.size.width * remoteCursorScale,
                    height: remoteCursor.size.height * remoteCursorScale
                )
                let hotspot = CGPoint(
                    x: remoteCursor.hotspot.x * remoteCursorScale,
                    y: remoteCursor.hotspot.y * remoteCursorScale
                )
                let cursorOrigin = CGPoint(
                    x: cursorLocation.x - hotspot.x,
                    y: cursorLocation.y - hotspot.y
                )

                fallbackCursorLayer.isHidden = true
                fallbackCursorLayer.frame = .zero
                cursorLayer.isHidden = false
                cursorLayer.frame = CGRect(origin: cursorOrigin,
                                           size: cursorSize)
                return
            }

            guard effectiveTouchMode == .trackpad,
                  showsTrackpadCursorDot else {
                hideCursorLayers()
                return
            }

            // Optional local position marker for transports that do not publish
            // cursor shapes. The host cursor remains the default presentation.
            cursorLayer.isHidden = true
            cursorLayer.frame = .zero
            fallbackCursorLayer.isHidden = false
            fallbackCursorLayer.frame = CGRect(
                x: cursorLocation.x - fallbackCursorDiameter / 2,
                y: cursorLocation.y - fallbackCursorDiameter / 2,
                width: fallbackCursorDiameter,
                height: fallbackCursorDiameter
            )
        }

        private var renderableRemoteCursor: RemoteCursor? {
            guard let remoteCursor,
                  remoteCursor.size.width.isFinite,
                  remoteCursor.size.height.isFinite,
                  remoteCursor.hotspot.x.isFinite,
                  remoteCursor.hotspot.y.isFinite,
                  remoteCursor.size.width > 0,
                  remoteCursor.size.height > 0 else {
                return nil
            }

            return remoteCursor
        }

        private func hideCursorLayers() {
            cursorLayer.isHidden = true
            cursorLayer.frame = .zero
            fallbackCursorLayer.isHidden = true
            fallbackCursorLayer.frame = .zero
        }

#if DEBUG
        var debugFramebufferFrame: CGRect {
            framebufferView.frame
        }

        var debugZoomScale: CGFloat {
            zoomScale
        }

        var debugMinimumZoomScale: CGFloat {
            minimumZoomScale
        }

        var debugManualViewportPositionActive: Bool {
            manualViewportPositionActive
        }

        func debugRouteTwoFingerTouchPan(by translation: CGPoint) {
            touchScrollAccumulator = .zero
            touchPendingTranslation = .zero
            touchPanIntent = .undecided
            routeTouchPan(translation, forcesViewportPan: false)
        }

        func debugRouteContinuousPointerPan(by translation: CGPoint) {
            pointerScrollAccumulator = .zero
            pointerPendingTranslation = .zero
            pointerPanIntent = .undecided
            routePointerPan(translation)
        }

        func debugRouteDiscretePointerWheel(by translation: CGPoint) {
            pointerWheelScrollAccumulator = .zero
            forwardScroll(delta: translation,
                          accumulator: &pointerWheelScrollAccumulator)
        }

        var debugCursorIsVisible: Bool {
            !cursorLayer.isHidden || !fallbackCursorLayer.isHidden
        }

        var debugUsesFallbackCursor: Bool {
            !fallbackCursorLayer.isHidden
        }

        var debugCursorFrame: CGRect {
            fallbackCursorLayer.isHidden ? cursorLayer.frame : fallbackCursorLayer.frame
        }
#endif

        private func cursorLocationDidChange() {
            let previousCursor = lastLocalCursorLocation
            lastLocalCursorLocation = localCursorLocation()
            revealCursorIfNeeded(previousCursor: previousCursor,
                                 requiresOutwardMovement: true,
                                 allowsManualViewportOverride: true)
            updateCursorLayerFrame()
        }

        private func clampedViewportCenter(_ center: CGPoint,
                                           renderedSize: CGSize) -> CGPoint {
            return CGPoint(x: clampedViewportCoordinate(center.x,
                                                        imageLength: imageSize.width,
                                                        renderedLength: renderedSize.width,
                                                        viewportLength: bounds.width),
                           y: clampedViewportCoordinate(center.y,
                                                        imageLength: imageSize.height,
                                                        renderedLength: renderedSize.height,
                                                        viewportLength: bounds.height))
        }

        private func clampedViewportCoordinate(_ coordinate: CGFloat,
                                               imageLength: CGFloat,
                                               renderedLength: CGFloat,
                                               viewportLength: CGFloat) -> CGFloat {
            guard renderedLength > viewportLength else {
                return imageLength / 2
            }

            let visibleHalfLength = viewportLength / (2 * effectiveScale)
            let lowerBound = visibleHalfLength
            let upperBound = imageLength - visibleHalfLength

            return min(max(coordinate, lowerBound), upperBound)
        }

        private func revealCursorIfNeeded(previousCursor: CGPoint? = nil,
                                          requiresOutwardMovement: Bool,
                                          allowsManualViewportOverride: Bool = false) {
            guard followsCursor, zoomScale > minimumZoomScale,
                  !manualViewportPositionActive || allowsManualViewportOverride,
                  let localCursor = localCursorLocation() else { return }

            let renderedSize = CGSize(width: imageSize.width * effectiveScale,
                                      height: imageSize.height * effectiveScale)
            let currentCenter = clampedViewportCenter(
                viewportCenter ?? CGPoint(x: imageSize.width / 2,
                                          y: imageSize.height / 2),
                renderedSize: renderedSize
            )
            let candidate = RemoteViewportGeometry.centerRevealingCursor(
                currentCenter,
                cursor: localCursor,
                previousCursor: previousCursor,
                contentSize: imageSize,
                viewportSize: bounds.size,
                effectiveScale: effectiveScale,
                requiresOutwardMovement: requiresOutwardMovement
            )
            let revealedCenter = clampedViewportCenter(candidate,
                                                       renderedSize: renderedSize)
            guard revealedCenter != currentCenter else { return }

            manualViewportPositionActive = false
            viewportCenter = revealedCenter
            updateFramebufferViewFrame()
            logViewport("Cursor following moved viewport; from=\(Self.pointDescription(currentCenter)) to=\(Self.pointDescription(revealedCenter)) cursor=\(Self.pointDescription(localCursor)) requiresOutwardMovement=\(requiresOutwardMovement)")
        }

        // MARK: - Multi-finger gestures

        @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            rightClick(from: gesture, usesPointerLocation: false)
        }

        @objc private func handlePointerSecondaryTap(_ gesture: UITapGestureRecognizer) {
            rightClick(from: gesture, usesPointerLocation: true)
        }

        private func rightClick(from gesture: UITapGestureRecognizer,
                                usesPointerLocation: Bool) {
            guard let session else { return }

            becomeFirstResponderIfAppropriate()

            switch effectiveTouchMode {
            case .trackpad:
                if usesPointerLocation,
                   let point = framebufferPoint(for: gesture.location(in: self)) {
                    session.rightClick(at: point)
                } else {
                    session.rightClickAtCursor()
                }

            case .direct:
                if let point = framebufferPoint(for: gesture.location(in: self)) {
                    session.rightClick(at: point)
                }
            }

            cursorLocationDidChange()
        }

        @objc private func handleTouchPan(_ gesture: UIPanGestureRecognizer) {
            guard session != nil else { return }

            switch gesture.state {
            case .began:
                touchScrollAccumulator = .zero
                touchPendingTranslation = .zero
                touchPanIntent = .undecided
#if DEBUG
                loggedTouchPanTranslation = .zero
#endif
                suppressPinchIfThreeFingerPan(gesture)
                enterMultiTouch()
                logViewport("Touch pan began; touches=\(gesture.numberOfTouches)")

            case .changed:
                let delta = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                suppressPinchIfThreeFingerPan(gesture)
                routeTouchPan(delta,
                              forcesViewportPan: gesture.numberOfTouches >= 3)

            default:
                logViewport("Touch pan ended; state=\(Self.gestureStateDescription(gesture.state)) intent=\(Self.gestureIntentDescription(touchPanIntent)) totalTranslation=\(Self.pointDescription(loggedTouchPanTranslationForDiagnostics))")
                touchScrollAccumulator = .zero
                touchPendingTranslation = .zero
                touchPanIntent = .undecided
            }
        }

        private func suppressPinchIfThreeFingerPan(
            _ gesture: UIPanGestureRecognizer
        ) {
            guard gesture.numberOfTouches >= 3 else { return }

            pinchIsSuppressedByThreeFingerPan = true
            pinchIsActive = false
        }

        @objc private func handlePointerScroll(_ gesture: UIPanGestureRecognizer) {
            guard session != nil else { return }

            switch gesture.state {
            case .began:
                pointerScrollAccumulator = .zero
                pointerPendingTranslation = .zero
                pointerPanIntent = .undecided
#if DEBUG
                loggedPointerPanTranslation = .zero
#endif
                becomeFirstResponderIfAppropriate()
                logViewport("Pointer pan began")

            case .changed:
                let delta = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)

                routePointerPan(delta)

            default:
                logViewport("Pointer pan ended; state=\(Self.gestureStateDescription(gesture.state)) intent=\(Self.gestureIntentDescription(pointerPanIntent)) totalTranslation=\(Self.pointDescription(loggedPointerPanTranslationForDiagnostics))")
                pointerScrollAccumulator = .zero
                pointerPendingTranslation = .zero
                pointerPanIntent = .undecided
            }
        }

        @objc private func handlePointerWheelScroll(_ gesture: UIPanGestureRecognizer) {
            guard session != nil else { return }

            switch gesture.state {
            case .began:
                pointerWheelScrollAccumulator = .zero
                becomeFirstResponderIfAppropriate()

            case .changed:
                let delta = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                forwardScroll(delta: delta,
                              accumulator: &pointerWheelScrollAccumulator)

            default:
                pointerWheelScrollAccumulator = .zero
            }
        }

        private var pannableViewportAxes: RemoteViewportGeometry.PannableAxes {
            RemoteViewportGeometry.pannableAxes(contentSize: imageSize,
                                                viewportSize: bounds.size,
                                                effectiveScale: effectiveScale)
        }

        private func routeTouchPan(_ delta: CGPoint,
                                   forcesViewportPan: Bool) {
#if DEBUG
            loggedTouchPanTranslation.x += delta.x
            loggedTouchPanTranslation.y += delta.y
#endif
            touchPendingTranslation.x += delta.x
            touchPendingTranslation.y += delta.y

            if forcesViewportPan || pinchIsActive {
                if touchPanIntent != .viewportPan {
                    logViewport("Touch pan routed to viewport; reason=\(forcesViewportPan ? "three-finger" : "pinch") pendingTranslation=\(Self.pointDescription(touchPendingTranslation))")
                }
                touchPanIntent = .viewportPan
                touchScrollAccumulator = .zero
            } else if touchPanIntent == .undecided {
                let candidateIntent = RemoteViewportGeometry.gestureIntent(
                    pannableAxes: pannableViewportAxes,
                    pansViewportWithTwoFingers: pansViewportWithTwoFingers,
                    forcesViewportPan: keyboardAvoidanceActive
                )
                if candidateIntent == .remoteScroll,
                   !RemoteViewportGeometry.shouldCommitRemoteScroll(
                    translation: touchPendingTranslation
                   ) {
                    return
                }
                touchPanIntent = candidateIntent
                logViewport("Touch pan intent resolved; intent=\(Self.gestureIntentDescription(candidateIntent)) pendingTranslation=\(Self.pointDescription(touchPendingTranslation))")
            }

            let routedDelta = touchPendingTranslation
            touchPendingTranslation = .zero

            switch touchPanIntent {
            case .viewportPan:
                panViewport(by: routedDelta)
            case .remoteScroll:
                forwardScroll(delta: routedDelta,
                              accumulator: &touchScrollAccumulator)
            case .undecided:
                break
            }
        }

        private func routePointerPan(_ delta: CGPoint) {
#if DEBUG
            loggedPointerPanTranslation.x += delta.x
            loggedPointerPanTranslation.y += delta.y
#endif
            pointerPendingTranslation.x += delta.x
            pointerPendingTranslation.y += delta.y

            if pinchIsActive {
                if pointerPanIntent != .viewportPan {
                    logViewport("Pointer pan routed to viewport during pinch; pendingTranslation=\(Self.pointDescription(pointerPendingTranslation))")
                }
                pointerPanIntent = .viewportPan
                pointerScrollAccumulator = .zero
            } else if pointerPanIntent == .undecided {
                let candidateIntent = RemoteViewportGeometry.gestureIntent(
                    pannableAxes: pannableViewportAxes,
                    pansViewportWithTwoFingers: pansViewportWithTwoFingers,
                    forcesViewportPan: keyboardAvoidanceActive
                )
                if candidateIntent == .remoteScroll,
                   !RemoteViewportGeometry.shouldCommitRemoteScroll(
                    translation: pointerPendingTranslation
                   ) {
                    return
                }
                pointerPanIntent = candidateIntent
                logViewport("Pointer pan intent resolved; intent=\(Self.gestureIntentDescription(candidateIntent)) pendingTranslation=\(Self.pointDescription(pointerPendingTranslation))")
            }

            let routedDelta = pointerPendingTranslation
            pointerPendingTranslation = .zero

            switch pointerPanIntent {
            case .viewportPan:
                panViewport(by: routedDelta)
            case .remoteScroll:
                forwardScroll(delta: routedDelta,
                              accumulator: &pointerScrollAccumulator)
            case .undecided:
                break
            }
        }

        private func panViewport(by translation: CGPoint) {
            let axes = pannableViewportAxes
            guard !axes.isEmpty else {
                logViewport("Viewport pan ignored; no pannable axes translation=\(Self.pointDescription(translation))")
                return
            }

            let renderedSize = CGSize(width: imageSize.width * effectiveScale,
                                      height: imageSize.height * effectiveScale)
            let currentCenter = clampedViewportCenter(
                viewportCenter ?? CGPoint(x: imageSize.width / 2,
                                          y: imageSize.height / 2),
                renderedSize: renderedSize
            )
            let candidate = RemoteViewportGeometry.centerByPanning(
                currentCenter,
                translation: translation,
                pannableAxes: axes,
                effectiveScale: effectiveScale
            )
            let pannedCenter = clampedViewportCenter(candidate,
                                                     renderedSize: renderedSize)
            guard pannedCenter != currentCenter else {
                logViewport("Viewport pan stopped at boundary; translation=\(Self.pointDescription(translation)) current=\(Self.pointDescription(currentCenter)) candidate=\(Self.pointDescription(candidate)) clamped=\(Self.pointDescription(pannedCenter))")
                return
            }

            if pannedCenter != candidate {
                logViewport("Viewport pan reached boundary; translation=\(Self.pointDescription(translation)) current=\(Self.pointDescription(currentCenter)) candidate=\(Self.pointDescription(candidate)) clamped=\(Self.pointDescription(pannedCenter))")
            }

            manualViewportPositionActive = true
            viewportCenter = pannedCenter
            updateFramebufferViewFrame()
        }

        @objc private func handlePointerHover(_ gesture: UIHoverGestureRecognizer) {
            guard let session,
                  gesture.state == .began || gesture.state == .changed,
                  let point = framebufferPoint(for: gesture.location(in: self)) else {
                return
            }

            becomeFirstResponderIfAppropriate()
            session.moveCursor(to: point)
            cursorLocationDidChange()
        }

        private func forwardScroll(delta: CGPoint,
                                   accumulator: inout CGPoint) {
            accumulator.x += delta.x
            accumulator.y += delta.y

            let horizontalSteps = Int(abs(accumulator.x) / scrollStep)

            if horizontalSteps > 0 {
                let direction: RemoteScrollDirection =
                    accumulator.x > 0 ? .left : .right

                session?.scroll(direction, steps: UInt32(horizontalSteps))

                accumulator.x -= CGFloat(horizontalSteps) * scrollStep
                    * (accumulator.x > 0 ? 1 : -1)
            }

            let verticalSteps = Int(abs(accumulator.y) / scrollStep)

            if verticalSteps > 0 {
                // Natural direction: fingers down -> content follows (wheel up).
                let direction: RemoteScrollDirection =
                    accumulator.y > 0 ? .up : .down

                session?.scroll(direction, steps: UInt32(verticalSteps))

                accumulator.y -= CGFloat(verticalSteps) * scrollStep
                    * (accumulator.y > 0 ? 1 : -1)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            gestureRecognizer !== pointerScrollPan
                && gestureRecognizer !== pointerWheelScrollPan
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            let pair = [gestureRecognizer, otherGestureRecognizer]
            return pair.contains { $0 === pinchGesture }
                && pair.contains { $0 === touchPanGesture || $0 === pointerScrollPan }
        }

        // MARK: - Single-finger touch handling

        private func activeTouchCount(_ event: UIEvent?) -> Int {
            event?.allTouches?.filter {
                $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
            }.count ?? 0
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first, let session else { return }

            becomeFirstResponderIfAppropriate()

            // Second finger down → this is a two-finger gesture. Abort any
            // single-finger interaction and let the recognizers take over.
            if activeTouchCount(event) >= 2 {
                enterMultiTouch()
                return
            }

            let location = touch.location(in: self)

            switch effectiveTouchMode {
            case .trackpad:
                relativePointer.begin(
                    touchLocation: location,
                    cursorLocation: session.cursorLocation
                )
                touchStartTime = touch.timestamp
                touchMoved = false
                isDragging = false
                multiTouchActive = false
                scheduleLongPress()

            case .direct:
                guard let point = framebufferPoint(for: location) else { return }

                multiTouchActive = false
                pendingPressPoint = point
                schedulePendingPress()
            }
        }

        // MARK: - Hardware keyboard input

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let session else {
                super.pressesBegan(presses, with: event)
                return
            }

            var unhandledPresses = Set<UIPress>()

            for press in presses {
                guard let key = press.key else {
                    unhandledPresses.insert(press)
                    continue
                }

                if routesThroughSystemPaste(keyCode: key.keyCode, modifiers: key.modifierFlags) {
                    // UIKit must see the native paste gesture. Forwarding "v"
                    // here would paste the Mac's old clipboard as well.
                    unhandledPresses.insert(press)
                    continue
                }

                if let keyCode = HardwareKeyboardKeyMapper.keyCode(for: key.keyCode) {
                    let modifiers = HardwareKeyboardKeyMapper.modifierKeyCodes(
                        for: key.modifierFlags,
                        includeShift: true
                    )

                    session.sendKey(keyCode, modifiers: modifiers)
                } else if !sendText(for: key, through: session) {
                    unhandledPresses.insert(press)
                }
            }

            if !unhandledPresses.isEmpty {
                super.pressesBegan(unhandledPresses, with: event)
            }
        }

        private func sendText(for key: UIKey, through session: any RemoteSessionInputControlling) -> Bool {
            let shortcutModifiers: UIKeyModifierFlags = [.command, .control, .alternate]
            let shouldForwardShortcut = !key.modifierFlags.intersection(shortcutModifiers).isEmpty

            if shouldForwardShortcut, !key.charactersIgnoringModifiers.isEmpty {
                let modifiers = HardwareKeyboardKeyMapper.modifierKeyCodes(
                    for: key.modifierFlags,
                    includeShift: true
                )

                session.sendText(key.charactersIgnoringModifiers, modifiers: modifiers)
                return true
            }

            guard !key.characters.isEmpty else { return false }

            session.sendText(key.characters)
            return true
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first, let session,
                  !multiTouchActive, activeTouchCount(event) < 2 else { return }

            let location = touch.location(in: self)

            switch effectiveTouchMode {
            case .trackpad:
                guard let requestedTarget = relativePointer.advance(
                    to: location,
                    framebufferScale: effectiveScale
                ) else { return }

                if !touchMoved,
                   relativePointer.hasMoved(beyond: tapMovementThreshold) {
                    touchMoved = true
                    cancelLongPress()
                }

                // Keep the gesture's own absolute target. Glassy Stream also
                // receives asynchronous host cursor telemetry, which may
                // describe an older pointer command. Rebasing every delta on
                // that telemetry makes the next command jump backwards.
                session.moveCursor(to: requestedTarget, dragging: isDragging)
                relativePointer.synchronizeTarget(to: session.cursorLocation)
                cursorLocationDidChange()

            case .direct:
                guard let point = framebufferPoint(for: location) else { return }

                // Movement before the debounce fired → press immediately so
                // dragging stays responsive.
                firePendingPressIfNeeded()

                guard directPressed else { return }

                // Button stays pressed while coordinates change → drag.
                session.leftButtonDown(at: point)
                cursorLocationDidChange()
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first, let session else { return }

            if multiTouchActive {
                if activeTouchCount(event) == 0 { multiTouchActive = false }
                return
            }

            switch effectiveTouchMode {
            case .trackpad:
                cancelLongPress()

                if isDragging {
                    let point = relativePointer.target ?? session.cursorLocation
                    session.leftButtonUp(at: point)
                    isDragging = false
                } else if !touchMoved,
                          touch.timestamp - touchStartTime < tapDurationThreshold {
                    let point = relativePointer.target ?? session.cursorLocation
                    session.leftButtonDown(at: point)
                    session.leftButtonUp(at: point)
                }
                relativePointer.reset()

            case .direct:
                // Tap ended before the debounce → full click now.
                firePendingPressIfNeeded()

                guard directPressed else { return }

                directPressed = false

                let point = framebufferPoint(for: touch.location(in: self))
                    ?? session.cursorLocation
                session.leftButtonUp(at: point)
                cursorLocationDidChange()
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let session else { return }

            cancelLongPress()
            cancelPendingPress()

            if isDragging {
                let point = relativePointer.target ?? session.cursorLocation
                session.leftButtonUp(at: point)
                isDragging = false
            }
            relativePointer.reset()

            if directPressed {
                directPressed = false
                session.leftButtonUp(at: session.cursorLocation)
                cursorLocationDidChange()
            }

            if activeTouchCount(event) == 0 { multiTouchActive = false }
        }

        private var effectiveTouchMode: RemoteTouchMode {
            touchModeOverride ?? session?.touchMode ?? .direct
        }

        private func enterMultiTouch() {
            multiTouchActive = true

            cancelLongPress()
            cancelPendingPress()

            if isDragging {
                if let session {
                    let point = relativePointer.target ?? session.cursorLocation
                    session.leftButtonUp(at: point)
                }
                isDragging = false
            }
            relativePointer.reset()

            if directPressed {
                directPressed = false
                session?.leftButtonUp(at: session?.cursorLocation ?? .zero)
                cursorLocationDidChange()
            }
        }

        // MARK: - Deferred press (direct mode)

        private func schedulePendingPress() {
            cancelPendingPress()

            let pressDebounce = Int(pressDebounce * 1000)
            pendingPressTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(pressDebounce))
                guard !Task.isCancelled else { return }
                self?.firePendingPressIfNeeded()
            }
        }

        private func firePendingPressIfNeeded() {
            guard let point = pendingPressPoint else { return }

            cancelPendingPress()
            pendingPressPoint = nil
            directPressed = true
            session?.leftButtonDown(at: point)
            cursorLocationDidChange()
        }

        private func cancelPendingPress() {
            pendingPressTask?.cancel()
            pendingPressTask = nil
        }

        // MARK: - Long-press → drag (trackpad mode)

        private func scheduleLongPress() {
            let longPressDelay = Int(longPressDelay * 1000)
            longPressTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(longPressDelay))
                guard !Task.isCancelled else { return }
                guard let self, !self.touchMoved, !self.isDragging,
                      !self.multiTouchActive else { return }

                self.isDragging = true
                if let session = self.session {
                    let point = self.relativePointer.target ?? session.cursorLocation
                    session.leftButtonDown(at: point)
                    self.relativePointer.synchronizeTarget(to: session.cursorLocation)
                }

                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }

        private func cancelLongPress() {
            longPressTask?.cancel()
            longPressTask = nil
        }
    }
}
