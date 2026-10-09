@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import OSLog
import UIKit

/// Decides when a Standard VNC framebuffer is copied into the Picture in
/// Picture layer. Inline, one frame per second keeps the layer ready for the
/// start animation without measurable cost. While the window is active the
/// mirror follows the desktop at up to fifteen frames per second.
struct FramebufferPictureInPictureThrottle: Equatable, Sendable {
    static let inlineInterval: TimeInterval = 1
    static let activeInterval: TimeInterval = 1.0 / 15

    private(set) var lastSubmission: TimeInterval?

    mutating func shouldSubmit(at time: TimeInterval, isPictureInPictureActive: Bool) -> Bool {
        let interval = isPictureInPictureActive ? Self.activeInterval : Self.inlineInterval
        if let lastSubmission, time - lastSubmission < interval, time >= lastSubmission {
            return false
        }
        lastSubmission = time
        return true
    }

    mutating func reset() {
        lastSubmission = nil
    }
}

/// Copies Standard VNC framebuffer images into an `AVSampleBufferDisplayLayer`
/// so AVKit can show them in Picture in Picture. Fast Connection does not use
/// this type; its decoded H.264 layer is already a valid source.
@MainActor
final class FramebufferPictureInPictureFeeder {
    /// Picture in Picture windows are small. Scaling first keeps conversion
    /// cheap on large or multi-display Macs.
    nonisolated static let maximumLongEdge = 1_280

    private let worker: FramebufferPictureInPictureWorker
    private var throttle = FramebufferPictureInPictureThrottle()

    init(layer: AVSampleBufferDisplayLayer) {
        worker = FramebufferPictureInPictureWorker(renderer: layer.sampleBufferRenderer)
    }

    /// Offers the latest framebuffer image. `crop` selects the visible display
    /// in framebuffer coordinates; frames arriving faster than the current
    /// rate, or while the previous frame is still converting, are skipped.
    func submit(_ image: CGImage, crop: CGRect?, isPictureInPictureActive: Bool,
                at time: TimeInterval = CACurrentMediaTime()) {
        guard throttle.shouldSubmit(at: time, isPictureInPictureActive: isPictureInPictureActive) else { return }
        worker.render(image, crop: crop)
    }

    /// Forces the next offered image through, for example after the window opens.
    func invalidate() {
        throttle.reset()
    }

    func flush() {
        throttle.reset()
        worker.flush()
    }

    /// Creates an immediately displayed BGRA sample buffer no larger than
    /// `maximumLongEdge`, preserving the source aspect ratio.
    nonisolated static func makeSampleBuffer(from image: CGImage,
                                             crop: CGRect? = nil,
                                             maximumLongEdge: Int = maximumLongEdge,
                                             pool: inout FramebufferPixelBufferPool) -> CMSampleBuffer? {
        var source = image
        if let crop {
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let visible = crop.integral.intersection(bounds)
            if !visible.isNull, !visible.isEmpty, visible != bounds,
               let cropped = image.cropping(to: visible) {
                source = cropped
            }
        }

        guard source.width > 0, source.height > 0, maximumLongEdge > 0 else { return nil }
        let longEdge = max(source.width, source.height)
        let scale = min(1, Double(maximumLongEdge) / Double(longEdge))
        // Even dimensions keep every hardware scaler on its fast path.
        let width = max(2, Int((Double(source.width) * scale).rounded()) & ~1)
        let height = max(2, Int((Double(source.height) * scale).rounded()) & ~1)

        if pool.width != width || pool.height != height || pool.pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = FramebufferPixelBufferPool(pool: newPool, width: width, height: height)
        }

        guard let bufferPool = pool.pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, bufferPool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let drew: Bool = {
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.noneSkipFirst.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }()
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard drew else { return nil }

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}

/// A reusable pool for one output size.
struct FramebufferPixelBufferPool {
    var pool: CVPixelBufferPool?
    var width = 0
    var height = 0
}

/// Converts frames off the main thread. Only one conversion is in flight; the
/// throttle drops newer frames until it finishes, so a slow device cannot build
/// a backlog.
private final class FramebufferPictureInPictureWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.bunn.glassydesk.picture-in-picture.frames",
                                      qos: .userInitiated)
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var isRendering = false
    // Confined to `queue`.
    private var pool = FramebufferPixelBufferPool()

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    func flush() {
        queue.async { [self] in
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    func render(_ image: CGImage, crop: CGRect?) {
        let shouldRender = lock.withLock {
            guard !isRendering else { return false }
            isRendering = true
            return true
        }
        guard shouldRender else { return }

        queue.async { [self] in
            defer { lock.withLock { isRendering = false } }
            guard let sampleBuffer = FramebufferPictureInPictureFeeder.makeSampleBuffer(
                from: image,
                crop: crop,
                pool: &pool
            ) else {
                AppLog.rendering.debug("Skipped a Picture in Picture frame that could not be converted")
                return
            }
            if renderer.status == .failed {
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        }
    }
}

/// An opaque layer placed exactly beneath the Standard VNC framebuffer view.
/// It stays covered while the session is on screen; AVKit animates it into the
/// Picture in Picture window.
final class FramebufferPictureInPictureSourceView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        guard let layer = layer as? AVSampleBufferDisplayLayer else {
            preconditionFailure("FramebufferPictureInPictureSourceView requires AVSampleBufferDisplayLayer")
        }
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        sampleBufferLayer.videoGravity = .resizeAspect
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
