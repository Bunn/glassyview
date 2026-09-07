@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Observation
import OSLog

enum GlassyStreamVideoRendererState: Equatable, Sendable {
    case waitingForConfiguration
    case waitingForKeyFrame
    case rendering(width: Int32, height: Int32)
    case failed(String)
}

enum GlassyStreamVideoRendererError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case invalidAccessUnit(String)
    case invalidTiming(String)
    case coreMedia(operation: String, status: OSStatus)
    case decoder(String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(reason):
            String(localized: "Invalid remote video configuration: \(reason)")
        case let .invalidAccessUnit(reason):
            String(localized: "Invalid remote video frame: \(reason)")
        case let .invalidTiming(reason):
            String(localized: "Invalid remote video timing: \(reason)")
        case let .coreMedia(operation, status):
            String(localized: "\(operation) failed with Core Media status \(status).")
        case let .decoder(message):
            String(localized: "The hardware video decoder failed: \(message)")
        }
    }
}

/// Main-actor view state. Compressed media and AVFoundation decoding requests
/// run on one serial worker; no frame-sized payload is dispatched to main.
@MainActor
@Observable
final class GlassyStreamVideoRenderer {
    private(set) var state: GlassyStreamVideoRendererState = .waitingForConfiguration
    private(set) var enqueuedFrameCount = 0
    private(set) var droppedFrameCount = 0
    private(set) var videoDimensions: CGSize?
    private(set) var isDisplayingVideo = false

    @ObservationIgnored var onKeyFrameNeeded: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var onError: (@MainActor @Sendable (GlassyStreamVideoRendererError) -> Void)?
    @ObservationIgnored var onStateChanged: (@MainActor @Sendable (GlassyStreamVideoRendererState) -> Void)?
    @ObservationIgnored var onVideoDimensionsChanged: (@MainActor @Sendable (CGSize?) -> Void)?
    @ObservationIgnored var onPresentationReady: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored var onPresentationLost: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private let worker: GlassyStreamVideoWorker
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private weak var displayLayer: AVSampleBufferDisplayLayer?
    @ObservationIgnored private var readyObserver: GlassyStreamPresentationObservation?

    var mediaQueue: DispatchQueue { worker.queue }

    init() {
        worker = GlassyStreamVideoWorker()
        worker.notify = { [weak self] generation, event in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                switch event {
                case .snapshot(let state, let dimensions, let enqueued, let dropped):
                    self.enqueuedFrameCount = enqueued
                    self.droppedFrameCount = dropped
                    if self.videoDimensions != dimensions {
                        self.videoDimensions = dimensions
                        self.onVideoDimensionsChanged?(dimensions)
                    }
                    if self.state != state {
                        self.state = state
                        if (state == .waitingForConfiguration || state == .waitingForKeyFrame),
                           self.displayLayer?.isReadyForDisplay != true {
                            self.setPresentationReady(false)
                        }
                        self.onStateChanged?(state)
                    }
                case .keyFrameNeeded: self.onKeyFrameNeeded?()
                case .error(let error): self.onError?(error)
                }
            }
        }
        reset()
    }

    /// Invoke only on mediaQueue. The session captures this after each reset,
    /// so delayed events from an earlier connection cannot reach a new decoder.
    func makeMediaConsumer() -> @Sendable (GlassyStreamEvent) -> Bool {
        let generation = generation
        let worker = worker
        return { event in
            dispatchPrecondition(condition: .onQueue(worker.queue))
            guard worker.generation == generation else { return true }
            do { return try worker.consume(event) }
            catch { return true } // Worker already reports the fatal error.
        }
    }

    func reset() {
        generation = UUID()
        let generation = generation
        state = .waitingForConfiguration
        videoDimensions = nil
        enqueuedFrameCount = 0
        droppedFrameCount = 0
        isDisplayingVideo = false
        if let displayLayer { observePresentation(on: displayLayer) }
        worker.queue.async { [worker] in worker.reset(generation: generation) }
    }

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard displayLayer !== layer else { return }
        readyObserver = nil
        displayLayer = layer
        isDisplayingVideo = false
        let renderer = layer.sampleBufferRenderer
        worker.queue.async { [worker] in worker.attach(renderer) }
        observePresentation(on: layer)
    }

    private func observePresentation(on layer: AVSampleBufferDisplayLayer) {
        readyObserver = nil
        let identity = ObjectIdentifier(layer)
        let generation = generation
        let epoch = worker.presentationEpoch
        // This property is explicitly not KVO-observable. AVFoundation posts
        // this notification after real decoded output becomes displayable.
        let token = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
            object: layer, queue: nil
        ) { [weak self] _ in
            let observedEpoch = epoch.current
            Task { @MainActor [weak self] in
                self?.refreshPresentation(identity: identity, generation: generation, epoch: observedEpoch)
            }
        }
        readyObserver = GlassyStreamPresentationObservation(token)
        refreshPresentation(identity: identity, generation: generation, epoch: epoch.current)
    }

    private func refreshPresentation(identity: ObjectIdentifier, generation: UUID, epoch: UUID) {
        guard self.generation == generation, worker.presentationEpoch.current == epoch,
              let layer = displayLayer, ObjectIdentifier(layer) == identity else { return }
        // Read the current property; a delayed notification may describe an
        // earlier transition, or an earlier decoder recovery may have flushed.
        let ready = layer.isReadyForDisplay
        setPresentationReady(ready)
        if ready {
            worker.queue.async { [worker] in
                worker.presentationReady(generation: generation, epoch: epoch)
            }
        }
    }

    private func setPresentationReady(_ ready: Bool) {
        guard isDisplayingVideo != ready else { return }
        isDisplayingVideo = ready
        if ready { onPresentationReady?() } else { onPresentationLost?() }
    }

    func detach(from layer: AVSampleBufferDisplayLayer) {
        guard displayLayer === layer else { return }
        readyObserver = nil
        displayLayer = nil
        setPresentationReady(false)
        worker.queue.async { [worker] in worker.attach(nil) }
    }
}

/// Every mutable member below belongs to queue. Layer layout and attachment
/// identity stay in the facade; only its thread-safe sample renderer crosses.
final class GlassyStreamVideoWorker: @unchecked Sendable {
    enum Update: Sendable {
        case snapshot(GlassyStreamVideoRendererState, CGSize?, Int, Int)
        case keyFrameNeeded
        case error(GlassyStreamVideoRendererError)
    }
    let queue = DispatchQueue(label: "dev.bunn.glassydesk.video.media", qos: .userInteractive)
    var notify: (@Sendable (UUID, Update) -> Void)?
    private(set) var generation = UUID()
    private(set) var state: GlassyStreamVideoRendererState = .waitingForConfiguration {
        didSet { if state != oldValue { publishSnapshot() } }
    }
    private var enqueuedFrameCount = 0
    private var droppedFrameCount = 0
    private var videoDimensions: CGSize?
    private var sampleBufferRenderer: AVSampleBufferVideoRenderer?
    private var decoderFailureObserver: NSObjectProtocol?
    private var formatDescription: CMVideoFormatDescription?
    private var nalUnitHeaderLength = 0
    private var pendingAccessUnit: PendingAccessUnit?
    private var isRequestingMediaData = false
    private var isWaitingForKeyFrame = true
    private var didRequestKeyFrame = false
    private var mediaRequestGeneration = 0
    private var recoveryDeadline: DispatchWorkItem?
    private var scheduledRecoveryToken: UUID?
    private var recovery = GlassyStreamVideoRecoveryState()
    private var lastSnapshotTime: TimeInterval = 0
    fileprivate let presentationEpoch = GlassyStreamPresentationEpoch()

    deinit {
        recoveryDeadline?.cancel()
        sampleBufferRenderer?.stopRequestingMediaData()
        if let decoderFailureObserver { NotificationCenter.default.removeObserver(decoderFailureObserver) }
    }

    func configure(_ configuration: GlassyStreamVideoConfiguration) throws {
        try configure(
            parameterSets: configuration.parameterSets,
            nalUnitHeaderLength: configuration.nalUnitHeaderLength
        )
    }

    func enqueue(_ accessUnit: GlassyStreamVideoAccessUnit) throws {
        try enqueue(
            avccData: accessUnit.data,
            presentationTime: accessUnit.presentationTime,
            duration: accessUnit.duration,
            isKeyFrame: accessUnit.isKeyFrame
        )
    }

    /// Convenience entry point for a `GlassyStreamClientCallbacks.onEvent`
    /// bridge. Returns `true` when the event contained video media.
    @discardableResult
    func consume(_ event: GlassyStreamEvent) throws -> Bool {
        switch event {
        case let .videoConfiguration(configuration):
            try configure(configuration)
            return true

        case let .videoAccessUnit(accessUnit):
            try enqueue(accessUnit)
            return true

        case .videoDiscontinuity:
            recoverFromDecoderFailure(nil)
            return true

        case .hostStreamStatus(let status):
            recovery.setPaused(status.state != .starting && status.state != .streaming)
            synchronizeRecoveryDeadline()
            return false

        case .authenticated, .cursorPosition, .pong:
            return false
        }
    }

    /// Installs SPS/PPS from a `videoConfiguration` protocol message.
    /// Existing decoded images and queued samples are removed because a format
    /// change invalidates their decoder state.
    func configure(parameterSets: [Data], nalUnitHeaderLength: Int) throws {
        do {
            let description = try GlassyStreamSampleBufferBuilder.makeFormatDescription(
                parameterSets: parameterSets,
                nalUnitHeaderLength: nalUnitHeaderLength
            )

            stopPendingMediaRequest()
            flushDisplayedImage()
            formatDescription = description
            self.nalUnitHeaderLength = nalUnitHeaderLength
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            setVideoDimensions(
                CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
            )
            pendingAccessUnit = nil
            isWaitingForKeyFrame = true
            didRequestKeyFrame = false
            state = .waitingForKeyFrame
            recovery.begin()
            synchronizeRecoveryDeadline()
        } catch let error as GlassyStreamVideoRendererError {
            formatDescription = nil
            self.nalUnitHeaderLength = 0
            setVideoDimensions(nil)
            fail(error, resetDecoder: true)
            throw error
        }
    }

    /// Enqueues one host-timed AVCC access unit. Samples carry
    /// `DisplayImmediately`, so the host's monotonic clock never needs to be
    /// synchronized with the device clock and latency stays bounded.
    func enqueue(
        avccData: Data,
        presentationTime: TimeInterval,
        duration: TimeInterval?,
        isKeyFrame: Bool
    ) throws {
        guard formatDescription != nil, nalUnitHeaderLength > 0 else {
            let error = GlassyStreamVideoRendererError.invalidConfiguration(
                "a frame arrived before SPS/PPS"
            )
            fail(error, resetDecoder: false)
            throw error
        }

        do {
            try GlassyStreamSampleBufferBuilder.validateAccessUnit(
                avccData,
                nalUnitHeaderLength: nalUnitHeaderLength
            )
            try GlassyStreamSampleBufferBuilder.validateTiming(
                presentationTime: presentationTime,
                duration: duration
            )
        } catch let error as GlassyStreamVideoRendererError {
            fail(error, resetDecoder: true)
            throw error
        }

        guard let renderer = sampleBufferRenderer else {
            retainNewestSafeAccessUnit(
                PendingAccessUnit(
                    data: avccData,
                    presentationTime: presentationTime,
                    duration: duration,
                    isKeyFrame: isKeyFrame
                )
            )
            return
        }

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            recoverFromDecoderFailure(renderer.error?.localizedDescription)
        }

        let accessUnit = PendingAccessUnit(
            data: avccData,
            presentationTime: presentationTime,
            duration: duration,
            isKeyFrame: isKeyFrame
        )

        if pendingAccessUnit != nil {
            // Replacing a P-frame would break the reference chain. Clear the
            // single pending slot and recover at the newest keyframe instead.
            pendingAccessUnit = nil
            droppedFrameCount += 1
            enterKeyFrameRecovery()
        }

        if isWaitingForKeyFrame {
            guard accessUnit.isKeyFrame else {
                droppedFrameCount += 1
                requestKeyFrameIfNeeded()
                return
            }
        }

        guard renderer.isReadyForMoreMediaData else {
            pendingAccessUnit = accessUnit
            requestMediaDataWhenReady()
            return
        }

        try render(accessUnit, using: renderer)
    }

    /// Clears format, queued media, and the currently displayed image. Call
    /// this when a stream disconnects before reusing the renderer.
    func reset(generation: UUID) {
        self.generation = generation
        recoveryDeadline?.cancel()
        recoveryDeadline = nil
        scheduledRecoveryToken = nil
        recovery = GlassyStreamVideoRecoveryState()
        recovery.setAttached(sampleBufferRenderer != nil)
        stopPendingMediaRequest()
        pendingAccessUnit = nil
        formatDescription = nil
        nalUnitHeaderLength = 0
        setVideoDimensions(nil)
        isWaitingForKeyFrame = true
        didRequestKeyFrame = false
        enqueuedFrameCount = 0
        droppedFrameCount = 0
        flushDisplayedImage()
        state = .waitingForConfiguration
        if let decoderFailureObserver {
            NotificationCenter.default.removeObserver(decoderFailureObserver)
            self.decoderFailureObserver = nil
        }
        if let sampleBufferRenderer { installFailureObserver(for: sampleBufferRenderer) }
    }

    private func setVideoDimensions(_ dimensions: CGSize?) {
        guard videoDimensions != dimensions else { return }
        videoDimensions = dimensions
        publishSnapshot()
    }

    func attach(_ renderer: AVSampleBufferVideoRenderer?) {
        guard sampleBufferRenderer !== renderer else { return }
        detachCurrentRenderer()
        sampleBufferRenderer = renderer
        recovery.setAttached(renderer != nil)
        if let renderer { installFailureObserver(for: renderer) }
        if formatDescription != nil, renderer != nil {
            pendingAccessUnit = nil
            didRequestKeyFrame = false
            enterKeyFrameRecovery()
        }
        synchronizeRecoveryDeadline()
    }

    private func retainNewestSafeAccessUnit(_ accessUnit: PendingAccessUnit) {
        if pendingAccessUnit != nil {
            pendingAccessUnit = nil
            droppedFrameCount += 1
            enterKeyFrameRecovery()
        }

        guard !isWaitingForKeyFrame || accessUnit.isKeyFrame else {
            droppedFrameCount += 1
            requestKeyFrameIfNeeded()
            return
        }

        pendingAccessUnit = accessUnit
    }

    private func render(
        _ accessUnit: PendingAccessUnit,
        using renderer: AVSampleBufferVideoRenderer
    ) throws {
        guard let formatDescription else { return }

        do {
            let sampleBuffer = try GlassyStreamSampleBufferBuilder.makeSampleBuffer(
                accessUnit: accessUnit,
                formatDescription: formatDescription
            )
            renderer.enqueue(sampleBuffer)
        } catch let error as GlassyStreamVideoRendererError {
            fail(error, resetDecoder: true)
            throw error
        }

        if accessUnit.isKeyFrame {
            isWaitingForKeyFrame = false
            didRequestKeyFrame = false
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        enqueuedFrameCount += 1
        state = .rendering(width: dimensions.width, height: dimensions.height)
        if ProcessInfo.processInfo.systemUptime - lastSnapshotTime > 0.5 { publishSnapshot() }
    }

    private func requestMediaDataWhenReady() {
        guard !isRequestingMediaData,
              pendingAccessUnit != nil,
              let renderer = sampleBufferRenderer else {
            return
        }

        isRequestingMediaData = true
        let requestGeneration = mediaRequestGeneration
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, self.mediaRequestGeneration == requestGeneration,
                  let renderer = self.sampleBufferRenderer else { return }
            self.stopPendingMediaRequest()
            self.drainPendingAccessUnit(using: renderer)
        }
    }

    private func drainPendingAccessUnit(using renderer: AVSampleBufferVideoRenderer) {
        guard renderer.isReadyForMoreMediaData,
              let accessUnit = pendingAccessUnit else {
            requestMediaDataWhenReady()
            return
        }

        pendingAccessUnit = nil
        guard ProcessInfo.processInfo.systemUptime - accessUnit.receivedAt <= 0.15 else {
            droppedFrameCount += 1
            enterKeyFrameRecovery()
            return
        }
        do {
            try render(accessUnit, using: renderer)
        } catch {
            // `render` has already transitioned state and notified the owner.
        }
    }

    private func stopPendingMediaRequest() {
        mediaRequestGeneration &+= 1
        if isRequestingMediaData {
            sampleBufferRenderer?.stopRequestingMediaData()
            isRequestingMediaData = false
        }
    }

    private func enterKeyFrameRecovery() {
        if !isWaitingForKeyFrame || !recovery.awaitsPresentation {
            // A retained old image cannot prove this decoder recovered. A new
            // ready-for-display transition must follow the recovery keyframe.
            flushDisplayedImage()
            didRequestKeyFrame = false
        }
        isWaitingForKeyFrame = true
        state = .waitingForKeyFrame
        recovery.begin()
        synchronizeRecoveryDeadline()
        requestKeyFrameIfNeeded()
    }

    private func requestKeyFrameIfNeeded() {
        guard !didRequestKeyFrame else { return }
        didRequestKeyFrame = true
        notify?(generation, .keyFrameNeeded)
    }

    private func recoverFromDecoderFailure(_ underlyingErrorMessage: String?) {
        guard formatDescription != nil else { return }
        stopPendingMediaRequest()
        pendingAccessUnit = nil
        flushDisplayedImage()
        enterKeyFrameRecovery()
    }

    func presentationReady(generation: UUID, epoch: UUID) {
        guard self.generation == generation, presentationEpoch.current == epoch,
              !isWaitingForKeyFrame else { return }
        recovery.presentationReady()
        synchronizeRecoveryDeadline()
    }

    private func synchronizeRecoveryDeadline() {
        let token = recovery.deadlineToken
        guard token != scheduledRecoveryToken else { return }
        recoveryDeadline?.cancel()
        recoveryDeadline = nil
        scheduledRecoveryToken = token
        guard let token else { return }
        let activeGeneration = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == activeGeneration,
                  self.recovery.deadlineToken == token else { return }
            self.fail(.decoder("Video recovery timed out. Reconnect to request a fresh stream."), resetDecoder: false)
        }
        recoveryDeadline = item
        queue.asyncAfter(deadline: .now() + .seconds(5), execute: item)
    }

    private func fail(
        _ error: GlassyStreamVideoRendererError,
        resetDecoder: Bool
    ) {
        AppLog.rendering.error("\(error.localizedDescription, privacy: .public)")
        stopPendingMediaRequest()
        pendingAccessUnit = nil

        if resetDecoder {
            flushDisplayedImage()
            isWaitingForKeyFrame = true
            didRequestKeyFrame = false
            requestKeyFrameIfNeeded()
        }

        state = .failed(error.localizedDescription)
        notify?(generation, .error(error))
    }

    private func installFailureObserver(for renderer: AVSampleBufferVideoRenderer) {
        let generation = generation
        decoderFailureObserver = NotificationCenter.default.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: renderer, queue: nil
        ) { [weak self, weak renderer] notification in
            let message = (notification.userInfo?[
                AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey
            ] as? NSError)?.localizedDescription
            self?.queue.async { [weak self, weak renderer] in
                guard let self, let renderer, self.generation == generation,
                      self.sampleBufferRenderer === renderer else { return }
                self.recoverFromDecoderFailure(message)
            }
        }
    }

    private func detachCurrentRenderer() {
        stopPendingMediaRequest()
        recoveryDeadline?.cancel()
        recoveryDeadline = nil
        scheduledRecoveryToken = nil
        recovery.setAttached(false)
        if let decoderFailureObserver {
            NotificationCenter.default.removeObserver(decoderFailureObserver)
            self.decoderFailureObserver = nil
        }
        flushDisplayedImage()
        sampleBufferRenderer = nil
    }

    private func flushDisplayedImage() {
        presentationEpoch.invalidate()
        sampleBufferRenderer?.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    private func publishSnapshot() {
        lastSnapshotTime = ProcessInfo.processInfo.systemUptime
        notify?(generation, .snapshot(state, videoDimensions, enqueuedFrameCount, droppedFrameCount))
    }
}

/// Notification delivery can cross the media queue and MainActor. A flush
/// retires callbacks captured before it, even within the same connection.
fileprivate final class GlassyStreamPresentationEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID()
    var current: UUID { lock.withLock { value } }
    func invalidate() { lock.withLock { value = UUID() } }
}

private final class GlassyStreamPresentationObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// Pure deadline identity policy shared by every decoder recovery entry. A
/// keyframe enqueue is deliberately not completion; only presentation is.
struct GlassyStreamVideoRecoveryState: Sendable {
    private(set) var awaitsPresentation = false
    private(set) var deadlineToken: UUID?
    private var isPaused = false
    private var isAttached = false

    mutating func begin() {
        awaitsPresentation = true
        reconcile()
    }

    mutating func setPaused(_ paused: Bool) {
        isPaused = paused
        reconcile()
    }

    mutating func setAttached(_ attached: Bool) {
        isAttached = attached
        reconcile()
    }

    mutating func presentationReady() {
        awaitsPresentation = false
        deadlineToken = nil
    }

    private mutating func reconcile() {
        guard awaitsPresentation, isAttached, !isPaused else {
            deadlineToken = nil
            return
        }
        if deadlineToken == nil { deadlineToken = UUID() }
    }
}

private struct PendingAccessUnit {
    let receivedAt = ProcessInfo.processInfo.systemUptime
    let data: Data
    let presentationTime: TimeInterval
    let duration: TimeInterval?
    let isKeyFrame: Bool
}

private enum GlassyStreamSampleBufferBuilder {
    private static let maximumParameterSetBytes = 1 * 1024 * 1024
    private static let maximumAccessUnitBytes = 16 * 1024 * 1024
    private static let mediaTimescale: CMTimeScale = 1_000_000_000

    static func makeFormatDescription(
        parameterSets: [Data],
        nalUnitHeaderLength: Int
    ) throws -> CMVideoFormatDescription {
        guard (1...4).contains(nalUnitHeaderLength) else {
            throw GlassyStreamVideoRendererError.invalidConfiguration(
                "the AVCC NAL length field must be 1 through 4 bytes"
            )
        }
        guard (2...16).contains(parameterSets.count) else {
            throw GlassyStreamVideoRendererError.invalidConfiguration(
                "expected SPS and PPS parameter sets"
            )
        }
        guard parameterSets.allSatisfy({ !$0.isEmpty }) else {
            throw GlassyStreamVideoRendererError.invalidConfiguration(
                "parameter sets cannot be empty"
            )
        }

        let totalByteCount = parameterSets.reduce(into: 0) { total, parameterSet in
            total += parameterSet.count
        }
        guard totalByteCount <= maximumParameterSetBytes else {
            throw GlassyStreamVideoRendererError.invalidConfiguration(
                "parameter sets exceed the 1 MiB limit"
            )
        }

        let parameterSetTypes = parameterSets.compactMap { $0.first.map { $0 & 0x1F } }
        guard parameterSetTypes.contains(7), parameterSetTypes.contains(8) else {
            throw GlassyStreamVideoRendererError.invalidConfiguration(
                "both an H.264 SPS and PPS are required"
            )
        }

        var offsets: [Int] = []
        var sizes: [Int] = []
        var bytes: [UInt8] = []
        offsets.reserveCapacity(parameterSets.count)
        sizes.reserveCapacity(parameterSets.count)
        bytes.reserveCapacity(totalByteCount)

        for parameterSet in parameterSets {
            offsets.append(bytes.count)
            sizes.append(parameterSet.count)
            bytes.append(contentsOf: parameterSet)
        }

        var formatDescription: CMFormatDescription?
        let status = bytes.withUnsafeBufferPointer { byteBuffer -> OSStatus in
            guard let byteBaseAddress = byteBuffer.baseAddress else {
                return kCMFormatDescriptionError_InvalidParameter
            }

            let pointers = offsets.map { offset in
                UnsafePointer(byteBaseAddress.advanced(by: offset))
            }
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    guard let pointerBaseAddress = pointerBuffer.baseAddress,
                          let sizeBaseAddress = sizeBuffer.baseAddress else {
                        return kCMFormatDescriptionError_InvalidParameter
                    }

                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: pointerBaseAddress,
                        parameterSetSizes: sizeBaseAddress,
                        nalUnitHeaderLength: Int32(nalUnitHeaderLength),
                        formatDescriptionOut: &formatDescription
                    )
                }
            }
        }

        guard status == noErr, let formatDescription else {
            throw GlassyStreamVideoRendererError.coreMedia(
                operation: "Create H.264 format description",
                status: status
            )
        }
        return formatDescription
    }

    static func validateAccessUnit(
        _ data: Data,
        nalUnitHeaderLength: Int
    ) throws {
        guard !data.isEmpty, data.count <= maximumAccessUnitBytes else {
            throw GlassyStreamVideoRendererError.invalidAccessUnit(
                "payload size is outside the supported range"
            )
        }
        guard (1...4).contains(nalUnitHeaderLength) else {
            throw GlassyStreamVideoRendererError.invalidConfiguration(
                "the AVCC NAL length field must be 1 through 4 bytes"
            )
        }

        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var offset = 0
            var nalUnitCount = 0

            while offset < bytes.count {
                guard bytes.count - offset >= nalUnitHeaderLength else {
                    throw GlassyStreamVideoRendererError.invalidAccessUnit(
                        "a NAL length field is truncated"
                    )
                }

                var nalUnitLength = 0
                for index in 0..<nalUnitHeaderLength {
                    nalUnitLength = (nalUnitLength << 8) | Int(bytes[offset + index])
                }
                offset += nalUnitHeaderLength

                guard nalUnitLength > 0, nalUnitLength <= bytes.count - offset else {
                    throw GlassyStreamVideoRendererError.invalidAccessUnit(
                        "a NAL unit length exceeds the access-unit boundary"
                    )
                }

                offset += nalUnitLength
                nalUnitCount += 1
            }

            guard offset == bytes.count, nalUnitCount > 0 else {
                throw GlassyStreamVideoRendererError.invalidAccessUnit(
                    "the AVCC payload contains no complete NAL units"
                )
            }
        }
    }

    static func validateTiming(
        presentationTime: TimeInterval,
        duration: TimeInterval?
    ) throws {
        guard presentationTime.isFinite, presentationTime >= 0 else {
            throw GlassyStreamVideoRendererError.invalidTiming(
                "presentation time must be finite and nonnegative"
            )
        }
        if let duration {
            guard duration.isFinite, duration >= 0 else {
                throw GlassyStreamVideoRendererError.invalidTiming(
                    "duration must be finite and nonnegative"
                )
            }
        }

        let maximumSeconds = Double(Int64.max) / Double(mediaTimescale)
        guard presentationTime <= maximumSeconds,
              duration.map({ $0 <= maximumSeconds }) ?? true else {
            throw GlassyStreamVideoRendererError.invalidTiming(
                "timestamp exceeds the Core Media range"
            )
        }
    }

    static func makeSampleBuffer(
        accessUnit: PendingAccessUnit,
        formatDescription: CMVideoFormatDescription
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: accessUnit.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: accessUnit.data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw GlassyStreamVideoRendererError.coreMedia(
                operation: "Allocate H.264 block buffer",
                status: status
            )
        }

        status = accessUnit.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: accessUnit.data.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw GlassyStreamVideoRendererError.coreMedia(
                operation: "Copy H.264 access unit",
                status: status
            )
        }

        let presentationTimeStamp = CMTime(
            seconds: accessUnit.presentationTime,
            preferredTimescale: mediaTimescale
        )
        let duration = accessUnit.duration.map {
            CMTime(seconds: $0, preferredTimescale: mediaTimescale)
        } ?? .invalid
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = accessUnit.data.count
        var sampleBuffer: CMSampleBuffer?

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw GlassyStreamVideoRendererError.coreMedia(
                operation: "Create H.264 sample buffer",
                status: status
            )
        }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ),
        let attachment = (attachments as NSArray).firstObject as? NSMutableDictionary else {
            throw GlassyStreamVideoRendererError.invalidAccessUnit(
                "Core Media did not create sample attachments"
            )
        }

        attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
        attachment[kCMSampleAttachmentKey_NotSync] = !accessUnit.isKeyFrame
        return sampleBuffer
    }
}
