import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// A frame whose pixel buffer remains in ScreenCaptureKit's native IOSurface-backed form.
///
/// `CVPixelBuffer` is safe to retain across the capture and encoding queues. It is not
/// annotated as `Sendable` by the SDK, so this wrapper carries that responsibility while
/// deliberately exposing the buffer as read-only.
struct CapturedScreenFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTimeStamp: CMTime
    let duration: CMTime
}

struct CaptureDisplay: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    let isMain: Bool
}

struct ScreenCaptureConfiguration: Sendable {
    var framesPerSecond: Int
    var maximumWidth: Int?
    var maximumHeight: Int?
    var showsCursor: Bool

    init(
        framesPerSecond: Int = 60,
        maximumWidth: Int? = nil,
        maximumHeight: Int? = nil,
        showsCursor: Bool = true
    ) {
        self.framesPerSecond = max(1, framesPerSecond)
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.showsCursor = showsCursor
    }
}

enum ScreenCaptureServiceError: LocalizedError, Sendable {
    case noDisplaysAvailable
    case displayNotFound(CGDirectDisplayID)
    case startWasSuperseded

    var errorDescription: String? {
        switch self {
        case .noDisplaysAvailable:
            "No capturable display is available."
        case let .displayNotFound(displayID):
            "Display \(displayID) is no longer available."
        case .startWasSuperseded:
            "A newer capture request superseded this one."
        }
    }
}

enum ScreenCaptureEvent: Sendable {
    case started(displayID: CGDirectDisplayID, width: Int, height: Int)
    case stopped
    case failed(message: String)
}

/// Owns one ScreenCaptureKit display stream.
///
/// The public frame stream has a single-element newest-only buffer. If encoding or the
/// network stalls, an old unencoded frame is discarded rather than increasing latency.
actor ScreenCaptureService {
    typealias EventHandler = @Sendable (ScreenCaptureEvent) -> Void

    nonisolated let frames: AsyncStream<CapturedScreenFrame>

    private let frameContinuation: AsyncStream<CapturedScreenFrame>.Continuation
    private let eventHandler: EventHandler
    private var activeCapture: ActiveCapture?
    private var operationGeneration: UInt64 = 0

    init(eventHandler: @escaping EventHandler = { _ in }) {
        var continuation: AsyncStream<CapturedScreenFrame>.Continuation?
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        frameContinuation = continuation!
        self.eventHandler = eventHandler
    }

    func availableDisplays() async throws -> [CaptureDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let namesByDisplayID = await Self.displayNamesByID()
        let mainDisplayID = CGMainDisplayID()

        return content.displays.map { display in
            let size = Self.outputSize(
                for: display,
                maximumWidth: nil,
                maximumHeight: nil
            )
            return CaptureDisplay(
                id: display.displayID,
                name: namesByDisplayID[display.displayID]
                    ?? "Display \(display.displayID)",
                width: size.width,
                height: size.height,
                isMain: display.displayID == mainDisplayID
            )
        }
    }

    deinit {
        frameContinuation.finish()
    }

    /// Begins capturing the requested display, or the current main display when omitted.
    func start(
        displayID requestedDisplayID: CGDirectDisplayID? = nil,
        configuration: ScreenCaptureConfiguration = .init()
    ) async throws {
        operationGeneration &+= 1
        let generation = operationGeneration

        await stopActiveCapture(notify: false)
        guard generation == operationGeneration else {
            throw ScreenCaptureServiceError.startWasSuperseded
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard generation == operationGeneration else {
            throw ScreenCaptureServiceError.startWasSuperseded
        }

        let display = try Self.selectDisplay(
            from: content.displays,
            requestedDisplayID: requestedDisplayID
        )
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let outputSize = Self.outputSize(
            for: display,
            maximumWidth: configuration.maximumWidth,
            maximumHeight: configuration.maximumHeight
        )

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = outputSize.width
        streamConfiguration.height = outputSize.height
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.framesPerSecond)
        )
        // ScreenCaptureKit needs a small IOSurface pool, while our AsyncStream still
        // guarantees that only the newest unconsumed frame reaches the encoder.
        streamConfiguration.queueDepth = 3
        streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.capturesAudio = false

        let frameOutput = CaptureOutput(continuation: frameContinuation)
        let streamDelegate = CaptureStreamDelegate { [weak self] message in
            Task {
                await self?.captureDidStop(generation: generation, message: message)
            }
        }
        let stream = SCStream(
            filter: filter,
            configuration: streamConfiguration,
            delegate: streamDelegate
        )
        try stream.addStreamOutput(
            frameOutput,
            type: .screen,
            sampleHandlerQueue: frameOutput.queue
        )

        try await stream.startCapture()
        guard generation == operationGeneration else {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(frameOutput, type: .screen)
            throw ScreenCaptureServiceError.startWasSuperseded
        }

        activeCapture = ActiveCapture(
            generation: generation,
            displayID: display.displayID,
            stream: stream,
            output: frameOutput,
            delegate: streamDelegate
        )
        eventHandler(
            .started(
                displayID: display.displayID,
                width: outputSize.width,
                height: outputSize.height
            )
        )
    }

    func stop() async {
        operationGeneration &+= 1
        await stopActiveCapture(notify: true)
    }

    private func stopActiveCapture(notify: Bool) async {
        guard let activeCapture else { return }
        self.activeCapture = nil

        try? await activeCapture.stream.stopCapture()
        try? activeCapture.stream.removeStreamOutput(activeCapture.output, type: .screen)
        if notify {
            eventHandler(.stopped)
        }
    }

    private func captureDidStop(generation: UInt64, message: String) {
        guard activeCapture?.generation == generation else { return }
        activeCapture = nil
        eventHandler(.failed(message: message))
    }

    private static func selectDisplay(
        from displays: [SCDisplay],
        requestedDisplayID: CGDirectDisplayID?
    ) throws -> SCDisplay {
        guard !displays.isEmpty else {
            throw ScreenCaptureServiceError.noDisplaysAvailable
        }

        let displayID = requestedDisplayID ?? CGMainDisplayID()
        guard let display = displays.first(where: { $0.displayID == displayID }) else {
            if requestedDisplayID == nil, let firstDisplay = displays.first {
                return firstDisplay
            }
            throw ScreenCaptureServiceError.displayNotFound(displayID)
        }
        return display
    }

    private static func outputSize(
        for display: SCDisplay,
        maximumWidth: Int?,
        maximumHeight: Int?
    ) -> (width: Int, height: Int) {
        let displayMode = CGDisplayCopyDisplayMode(display.displayID)
        let nativeWidth = displayMode?.pixelWidth ?? display.width
        let nativeHeight = displayMode?.pixelHeight ?? display.height

        let widthScale = maximumWidth.map { Double($0) / Double(nativeWidth) } ?? 1
        let heightScale = maximumHeight.map { Double($0) / Double(nativeHeight) } ?? 1
        let scale = min(1, widthScale, heightScale)

        // Hardware H.264 encoders are happiest with even dimensions.
        let width = max(2, Int(Double(nativeWidth) * scale)) & ~1
        let height = max(2, Int(Double(nativeHeight) * scale)) & ~1
        return (width, height)
    }

    private static func displayNamesByID() async -> [CGDirectDisplayID: String] {
        await MainActor.run {
            var result: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
                guard let screenNumber = screen.deviceDescription[screenNumberKey]
                    as? NSNumber else {
                    continue
                }
                result[CGDirectDisplayID(screenNumber.uint32Value)] = screen.localizedName
            }
            return result
        }
    }
}

private extension ScreenCaptureService {
    struct ActiveCapture {
        let generation: UInt64
        let displayID: CGDirectDisplayID
        let stream: SCStream
        let output: CaptureOutput
        // SCStream's delegate is weak, so the service must retain it explicitly.
        let delegate: CaptureStreamDelegate
    }
}

private final class CaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(
        label: "dev.bunn.glassydesk.host.screen-capture",
        qos: .userInteractive
    )

    private let continuation: AsyncStream<CapturedScreenFrame>.Continuation

    init(continuation: AsyncStream<CapturedScreenFrame>.Continuation) {
        self.continuation = continuation
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let duration = sampleBuffer.duration.isValid
            ? sampleBuffer.duration
            : .invalid
        continuation.yield(
            CapturedScreenFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                duration: duration
            )
        )
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentArray.first,
              let rawStatus = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }
        return status == .complete
    }
}

private final class CaptureStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let stoppedHandler: @Sendable (String) -> Void

    init(stoppedHandler: @escaping @Sendable (String) -> Void) {
        self.stoppedHandler = stoppedHandler
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stoppedHandler(error.localizedDescription)
    }
}
