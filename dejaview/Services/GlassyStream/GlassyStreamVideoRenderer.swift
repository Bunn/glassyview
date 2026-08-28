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
            "Invalid Glassy Stream video configuration: \(reason)"
        case let .invalidAccessUnit(reason):
            "Invalid Glassy Stream video frame: \(reason)"
        case let .invalidTiming(reason):
            "Invalid Glassy Stream video timing: \(reason)"
        case let .coreMedia(operation, status):
            "\(operation) failed with Core Media status \(status)."
        case let .decoder(message):
            "The hardware video decoder failed: \(message)"
        }
    }
}

/// Converts Glassy Host's H.264 configuration and AVCC access units into
/// hardware-decoded sample buffers for an ``AVSampleBufferDisplayLayer``.
///
/// All renderer and display-layer interaction is main-actor isolated. A
/// network client can call these methods with `await` from its receive task.
/// The raw overloads deliberately mirror the host protocol so the transport
/// does not need to expose Core Media types.
@MainActor
@Observable
final class GlassyStreamVideoRenderer {
    private(set) var state: GlassyStreamVideoRendererState = .waitingForConfiguration {
        didSet {
            guard state != oldValue else { return }
            onStateChanged?(state)
        }
    }
    private(set) var renderedFrameCount = 0
    private(set) var droppedFrameCount = 0
    private(set) var videoDimensions: CGSize?

    /// Called once when a dropped dependency or decoder reset requires a new
    /// independently decodable access unit. The transport may map this to a
    /// keyframe request; periodic host keyframes remain a fallback.
    @ObservationIgnored
    var onKeyFrameNeeded: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored
    var onError: (@MainActor @Sendable (GlassyStreamVideoRendererError) -> Void)?

    @ObservationIgnored
    var onStateChanged: (@MainActor @Sendable (GlassyStreamVideoRendererState) -> Void)?

    @ObservationIgnored
    var onVideoDimensionsChanged: (@MainActor @Sendable (CGSize?) -> Void)?

    @ObservationIgnored
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    @ObservationIgnored
    private weak var sampleBufferRenderer: AVSampleBufferVideoRenderer?

    @ObservationIgnored
    private var decoderFailureObserver: NSObjectProtocol?

    @ObservationIgnored
    private var formatDescription: CMVideoFormatDescription?

    @ObservationIgnored
    private var nalUnitHeaderLength = 0

    @ObservationIgnored
    private var pendingAccessUnit: PendingAccessUnit?

    @ObservationIgnored
    private var isRequestingMediaData = false

    @ObservationIgnored
    private var isWaitingForKeyFrame = true

    @ObservationIgnored
    private var didRequestKeyFrame = false

    @ObservationIgnored
    private var mediaRequestGeneration = 0

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

        case .authenticated, .pong:
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
            sampleBufferRenderer?.flush(removingDisplayedImage: true, completionHandler: nil)
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
    func reset() {
        stopPendingMediaRequest()
        pendingAccessUnit = nil
        formatDescription = nil
        nalUnitHeaderLength = 0
        setVideoDimensions(nil)
        isWaitingForKeyFrame = true
        didRequestKeyFrame = false
        renderedFrameCount = 0
        droppedFrameCount = 0
        sampleBufferRenderer?.flush(removingDisplayedImage: true, completionHandler: nil)
        state = .waitingForConfiguration
    }

    private func setVideoDimensions(_ dimensions: CGSize?) {
        guard videoDimensions != dimensions else { return }
        videoDimensions = dimensions
        onVideoDimensionsChanged?(dimensions)
    }

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard displayLayer !== layer else { return }

        detachCurrentLayer(removingImage: true)

        displayLayer = layer
        let renderer = layer.sampleBufferRenderer
        sampleBufferRenderer = renderer
        installFailureObserver(for: renderer)

        if formatDescription != nil {
            // A new display layer has a fresh decoder. Its first sample must be
            // independently decodable even when the transport stayed alive.
            pendingAccessUnit = nil
            enterKeyFrameRecovery()
        }
    }

    func detach(from layer: AVSampleBufferDisplayLayer) {
        guard displayLayer === layer else { return }
        detachCurrentLayer(removingImage: false)

        if formatDescription != nil {
            pendingAccessUnit = nil
            isWaitingForKeyFrame = true
            didRequestKeyFrame = false
            state = .waitingForKeyFrame
        }
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
        renderedFrameCount += 1
        state = .rendering(width: dimensions.width, height: dimensions.height)
    }

    private func requestMediaDataWhenReady() {
        guard !isRequestingMediaData,
              pendingAccessUnit != nil,
              let renderer = sampleBufferRenderer else {
            return
        }

        isRequestingMediaData = true
        let requestGeneration = mediaRequestGeneration
        renderer.requestMediaDataWhenReady(on: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.mediaRequestGeneration == requestGeneration,
                      let renderer = self.sampleBufferRenderer else {
                    return
                }

                self.stopPendingMediaRequest()
                self.drainPendingAccessUnit(using: renderer)
            }
        }
    }

    private func drainPendingAccessUnit(using renderer: AVSampleBufferVideoRenderer) {
        guard renderer.isReadyForMoreMediaData,
              let accessUnit = pendingAccessUnit else {
            requestMediaDataWhenReady()
            return
        }

        pendingAccessUnit = nil
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
        isWaitingForKeyFrame = true
        didRequestKeyFrame = false
        state = .waitingForKeyFrame
        requestKeyFrameIfNeeded()
    }

    private func requestKeyFrameIfNeeded() {
        guard !didRequestKeyFrame else { return }
        didRequestKeyFrame = true
        onKeyFrameNeeded?()
    }

    private func recoverFromDecoderFailure(_ underlyingErrorMessage: String?) {
        let message = underlyingErrorMessage ?? "the decoder requires a reset"
        fail(.decoder(message), resetDecoder: true)
    }

    private func fail(
        _ error: GlassyStreamVideoRendererError,
        resetDecoder: Bool
    ) {
        AppLog.rendering.error("\(error.localizedDescription, privacy: .public)")
        stopPendingMediaRequest()
        pendingAccessUnit = nil

        if resetDecoder {
            sampleBufferRenderer?.flush(removingDisplayedImage: true, completionHandler: nil)
            isWaitingForKeyFrame = true
            didRequestKeyFrame = false
            requestKeyFrameIfNeeded()
        }

        state = .failed(error.localizedDescription)
        onError?(error)
    }

    private func installFailureObserver(for renderer: AVSampleBufferVideoRenderer) {
        decoderFailureObserver = NotificationCenter.default.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: renderer,
            queue: .main
        ) { [weak self] notification in
            let errorMessage = (notification.userInfo?[
                AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey
            ] as? NSError)?.localizedDescription

            Task { @MainActor [weak self] in
                self?.recoverFromDecoderFailure(errorMessage)
            }
        }
    }

    private func detachCurrentLayer(removingImage: Bool) {
        stopPendingMediaRequest()

        if let decoderFailureObserver {
            NotificationCenter.default.removeObserver(decoderFailureObserver)
            self.decoderFailureObserver = nil
        }

        sampleBufferRenderer?.flush(
            removingDisplayedImage: removingImage,
            completionHandler: nil
        )
        sampleBufferRenderer = nil
        displayLayer = nil
    }
}

private struct PendingAccessUnit {
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
