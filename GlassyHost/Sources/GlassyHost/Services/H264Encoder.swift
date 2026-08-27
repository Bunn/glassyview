import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import VideoToolbox

/// H.264 decoder configuration. Parameter sets are ordered exactly as VideoToolbox
/// reports them (normally SPS followed by PPS).
struct H264CodecConfiguration: Equatable, Sendable {
    let parameterSets: [Data]
    let nalUnitHeaderLength: Int
}

/// One AVCC-formatted access unit. NAL units retain VideoToolbox's length prefixes,
/// which makes the payload suitable for framing directly onto the host transport.
struct H264AccessUnit: Equatable, Sendable {
    let data: Data
    let presentationTimeSeconds: Double
    let durationSeconds: Double?
    let isKeyFrame: Bool
}

enum H264EncoderOutput: Equatable, Sendable {
    case codecConfiguration(H264CodecConfiguration)
    case accessUnit(H264AccessUnit)
}

struct H264EncoderConfiguration: Sendable {
    var expectedFrameRate: Int
    var averageBitRate: Int
    var keyFrameIntervalSeconds: Double

    init(
        expectedFrameRate: Int = 60,
        averageBitRate: Int = 12_000_000,
        keyFrameIntervalSeconds: Double = 2
    ) {
        self.expectedFrameRate = max(1, expectedFrameRate)
        self.averageBitRate = max(100_000, averageBitRate)
        self.keyFrameIntervalSeconds = max(0.25, keyFrameIntervalSeconds)
    }
}

struct H264EncoderError: LocalizedError, Sendable {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed with VideoToolbox status \(status)."
    }
}

/// Low-latency, real-time H.264 encoder backed by VideoToolbox.
///
/// Calls are serialized on a dedicated queue and VideoToolbox is limited to one delayed
/// frame with reordering disabled. Consume `ScreenCaptureService.frames` sequentially to
/// preserve its newest-frame-only backpressure behavior.
final class H264Encoder: @unchecked Sendable {
    typealias OutputHandler = @Sendable (H264EncoderOutput) -> Void
    typealias ErrorHandler = @Sendable (H264EncoderError) -> Void

    private let configuration: H264EncoderConfiguration
    private let queue = DispatchQueue(
        label: "dev.bunn.glassydesk.host.h264-encoder",
        qos: .userInteractive
    )
    private let callbackContext: H264CallbackContext

    private var compressionSession: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0
    private var forceNextKeyFrame = true

    init(
        configuration: H264EncoderConfiguration = .init(),
        outputHandler: @escaping OutputHandler,
        errorHandler: @escaping ErrorHandler = { _ in }
    ) {
        self.configuration = configuration
        callbackContext = H264CallbackContext(
            outputHandler: outputHandler,
            errorHandler: errorHandler
        )
    }

    deinit {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(
                compressionSession,
                untilPresentationTimeStamp: .invalid
            )
            VTCompressionSessionInvalidate(compressionSession)
        }
    }

    /// Submits one frame. Awaiting this method bounds work queued ahead of VideoToolbox.
    func encode(_ frame: CapturedScreenFrame, forceKeyFrame: Bool = false) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try encodeOnQueue(frame, forceKeyFrame: forceKeyFrame)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Forces the next submitted frame to be independently decodable. Use this when a
    /// newly authenticated viewer joins an existing host session.
    func requestKeyFrame() {
        queue.async { [weak self] in
            self?.forceNextKeyFrame = true
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                invalidateSessionOnQueue(completeFrames: true)
                continuation.resume()
            }
        }
    }

    private func encodeOnQueue(
        _ frame: CapturedScreenFrame,
        forceKeyFrame requestedKeyFrame: Bool
    ) throws {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        try prepareSessionOnQueue(width: width, height: height)

        guard let compressionSession else { return }

        let mustForceKeyFrame = requestedKeyFrame || forceNextKeyFrame
        forceNextKeyFrame = false
        let frameProperties: CFDictionary? = mustForceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        var infoFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        guard status == noErr else {
            throw H264EncoderError(operation: "Encode frame", status: status)
        }
    }

    private func prepareSessionOnQueue(width: Int, height: Int) throws {
        if compressionSession != nil,
           sessionWidth == width,
           sessionHeight == height {
            return
        }

        invalidateSessionOnQueue(completeFrames: true)

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: glassyHostCompressionOutputCallback,
            refcon: Unmanaged.passUnretained(callbackContext).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw H264EncoderError(operation: "Create compression session", status: status)
        }

        do {
            try setProperty(
                kVTCompressionPropertyKey_RealTime,
                value: kCFBooleanTrue,
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse,
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_MaxFrameDelayCount,
                value: NSNumber(value: 1),
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_Main_AutoLevel,
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_ExpectedFrameRate,
                value: NSNumber(value: configuration.expectedFrameRate),
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: configuration.averageBitRate),
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_DataRateLimits,
                value: [
                    NSNumber(value: configuration.averageBitRate / 8),
                    NSNumber(value: 1)
                ] as CFArray,
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: NSNumber(
                    value: Int(
                        Double(configuration.expectedFrameRate)
                            * configuration.keyFrameIntervalSeconds
                    )
                ),
                on: newSession
            )
            try setProperty(
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                value: NSNumber(value: configuration.keyFrameIntervalSeconds),
                on: newSession
            )
            if #available(macOS 13.0, *) {
                try setProperty(
                    kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                    value: kCFBooleanTrue,
                    on: newSession
                )
            }

            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(newSession)
            guard prepareStatus == noErr else {
                throw H264EncoderError(
                    operation: "Prepare compression session",
                    status: prepareStatus
                )
            }
        } catch {
            VTCompressionSessionInvalidate(newSession)
            throw error
        }

        compressionSession = newSession
        sessionWidth = width
        sessionHeight = height
        forceNextKeyFrame = true
        callbackContext.resetCodecConfiguration()
    }

    private func setProperty(
        _ key: CFString,
        value: CFTypeRef,
        on session: VTCompressionSession
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw H264EncoderError(
                operation: "Set \(key) compression property",
                status: status
            )
        }
    }

    private func invalidateSessionOnQueue(completeFrames: Bool) {
        guard let compressionSession else { return }
        self.compressionSession = nil
        sessionWidth = 0
        sessionHeight = 0

        if completeFrames {
            VTCompressionSessionCompleteFrames(
                compressionSession,
                untilPresentationTimeStamp: .invalid
            )
        }
        VTCompressionSessionInvalidate(compressionSession)
    }
}

private final class H264CallbackContext: @unchecked Sendable {
    private let outputHandler: H264Encoder.OutputHandler
    private let errorHandler: H264Encoder.ErrorHandler
    private let lock = NSLock()
    private var lastCodecConfiguration: H264CodecConfiguration?

    init(
        outputHandler: @escaping H264Encoder.OutputHandler,
        errorHandler: @escaping H264Encoder.ErrorHandler
    ) {
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
    }

    func resetCodecConfiguration() {
        lock.withLock {
            lastCodecConfiguration = nil
        }
    }

    func report(error: H264EncoderError) {
        errorHandler(error)
    }

    func emit(sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              sampleBuffer.dataReadiness == .ready,
              let payload = Self.copyPayload(from: sampleBuffer) else {
            return
        }

        let isKeyFrame = Self.isKeyFrame(sampleBuffer)
        if isKeyFrame,
           let configuration = Self.codecConfiguration(from: sampleBuffer),
           shouldEmit(configuration) {
            outputHandler(.codecConfiguration(configuration))
        }

        let presentationTime = sampleBuffer.presentationTimeStamp.seconds
        let duration = sampleBuffer.duration.seconds
        outputHandler(
            .accessUnit(
                H264AccessUnit(
                    data: payload,
                    presentationTimeSeconds: presentationTime.isFinite
                        ? presentationTime
                        : 0,
                    durationSeconds: duration.isFinite && duration > 0
                        ? duration
                        : nil,
                    isKeyFrame: isKeyFrame
                )
            )
        )
    }

    private func shouldEmit(_ configuration: H264CodecConfiguration) -> Bool {
        lock.withLock {
            guard configuration != lastCodecConfiguration else { return false }
            lastCodecConfiguration = configuration
            return true
        }
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]],
              let attachments = attachmentArray.first,
              let isNotSync = attachments[kCMSampleAttachmentKey_NotSync] as? Bool else {
            return true
        }
        return !isNotSync
    }

    private static func copyPayload(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = sampleBuffer.dataBuffer else { return nil }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: destination
            )
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    private static func codecConfiguration(
        from sampleBuffer: CMSampleBuffer
    ) -> H264CodecConfiguration? {
        guard let formatDescription = sampleBuffer.formatDescription else {
            return nil
        }

        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        var firstParameterSet: UnsafePointer<UInt8>?
        var firstParameterSetSize = 0
        let discoveryStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &firstParameterSet,
            parameterSetSizeOut: &firstParameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard discoveryStatus == noErr, parameterSetCount > 0 else {
            return nil
        }

        var parameterSets: [Data] = []
        parameterSets.reserveCapacity(parameterSetCount)
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else {
                return nil
            }
            parameterSets.append(Data(bytes: pointer, count: size))
        }

        return H264CodecConfiguration(
            parameterSets: parameterSets,
            nalUnitHeaderLength: Int(nalUnitHeaderLength)
        )
    }
}

private func glassyHostCompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let outputCallbackRefCon else { return }
    let context = Unmanaged<H264CallbackContext>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()

    guard status == noErr else {
        context.report(
            error: H264EncoderError(operation: "Compression callback", status: status)
        )
        return
    }
    guard !infoFlags.contains(.frameDropped), let sampleBuffer else { return }
    context.emit(sampleBuffer: sampleBuffer)
}
