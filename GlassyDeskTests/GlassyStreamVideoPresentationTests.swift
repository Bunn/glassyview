@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
import UIKit
@preconcurrency import VideoToolbox
@testable import GlassyDesk

/// Exercises the real encoder, decoder, and display notification. No test
/// invokes a readiness callback or changes a layer's readiness property.
@MainActor
@Suite(.serialized)
struct GlassyStreamVideoPresentationTests {
    @Test
    func decodedImageRemainsVisibleDuringRecovery() async throws {
        let first = try presentationFixture(width: 320, height: 180)
        let second = try presentationFixture(width: 480, height: 270)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 480, height: 320)
        window.rootViewController = UIViewController()
        window.isHidden = false
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = window.bounds
        window.rootViewController?.view.layer.addSublayer(layer)
        let renderer = GlassyStreamVideoRenderer()
        var failures: [String] = []
        var lostPresentations = 0
        renderer.onError = { failures.append($0.localizedDescription) }
        renderer.onPresentationLost = { lostPresentations += 1 }
        renderer.attach(to: layer)
        defer {
            renderer.detach(from: layer)
            renderer.reset()
            layer.removeFromSuperlayer()
            window.isHidden = true
        }
        let consume = renderer.makeMediaConsumer()
        renderer.mediaQueue.sync {
            _ = consume(.videoConfiguration(first.configuration))
            _ = consume(.videoAccessUnit(first.frame))
        }
        for _ in 0..<100 {
            if renderer.isDisplayingVideo { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let initialImage = try #require(layer.sampleBufferRenderer.displayedPixelBuffer())
        #expect(CVPixelBufferGetWidth(initialImage) == 320)
        for (event, fixture) in [(GlassyStreamEvent.videoDiscontinuity, first),
                                 (.videoConfiguration(second.configuration), second),
                                 (.videoDiscontinuity, second),
                                 (.videoConfiguration(first.configuration), first)] {
            renderer.mediaQueue.sync { _ = consume(event) }
            // Simulate a real network gap between recovery and its fresh IDR.
            // Inspect AVFoundation's displayed image, not facade state alone.
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(20))
                #expect(layer.sampleBufferRenderer.displayedPixelBuffer() != nil,
                        "Recovery must preserve the last decoded image while awaiting its replacement")
                #expect(renderer.isDisplayingVideo)
            }
            #expect(!layer.isReadyForDisplay,
                    "Retaining the previous image must not impersonate fresh decoded output")
            renderer.mediaQueue.sync { _ = consume(.videoAccessUnit(fixture.frame)) }
            for _ in 0..<100 {
                if layer.isReadyForDisplay { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(layer.isReadyForDisplay)
            let replacement = try #require(layer.sampleBufferRenderer.displayedPixelBuffer())
            #expect(CVPixelBufferGetWidth(replacement) == Int(fixture.dimensions.width))
            try await Task.sleep(for: .milliseconds(5_300))
            #expect(failures.isEmpty)
            #expect(lostPresentations == 0)
        }
        renderer.reset()
        #expect(!renderer.isDisplayingVideo)
        try await Task.sleep(for: .milliseconds(100))
        #expect(layer.sampleBufferRenderer.displayedPixelBuffer() == nil)
        #expect(!renderer.isDisplayingVideo)
    }

    @Test
    func decodedVideoSurvivesRecoveryDeadlineAndFormatReplacement() async throws {
        let first = try presentationFixture(width: 320, height: 180)
        let second = try presentationFixture(width: 480, height: 270)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 480, height: 320)
        window.rootViewController = UIViewController()
        window.isHidden = false
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = window.bounds
        window.rootViewController?.view.layer.addSublayer(layer)
        let renderer = GlassyStreamVideoRenderer()
        var failures: [String] = []
        var keyFrameRequests = 0
        renderer.onError = { failures.append($0.localizedDescription) }
        renderer.onKeyFrameNeeded = { keyFrameRequests += 1 }
        renderer.attach(to: layer)
        defer {
            renderer.detach(from: layer)
            renderer.reset()
            layer.removeFromSuperlayer()
            window.isHidden = true
        }

        for (index, fixture) in [first, second, first].enumerated() {
            if index == 2 {
                // Reuse the same physical layer for a new connection. Queued
                // notifications from its previous generation must be retired.
                renderer.reset()
            }
            let consume = renderer.makeMediaConsumer()
            renderer.mediaQueue.sync {
                _ = consume(.videoConfiguration(fixture.configuration))
                _ = consume(.videoAccessUnit(fixture.frame))
            }
            for _ in 0..<100 {
                if layer.isReadyForDisplay && renderer.isDisplayingVideo { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(layer.isReadyForDisplay, "The real H.264 decoder must produce a displayable image")
            #expect(renderer.isDisplayingVideo, "Native readiness must reach the facade without synthetic callbacks")
            // The original KVO observer never notified the facade and allowed
            // a visible, healthy stream to hit the five-second fatal deadline.
            try await Task.sleep(for: .milliseconds(5_300))
            #expect(failures.isEmpty)
            #expect(keyFrameRequests == 0, "Configuration followed by its IDR must not request a duplicate IDR")
            #expect(renderer.isDisplayingVideo)
            #expect(renderer.videoDimensions == fixture.dimensions)
            #expect(renderer.state == .rendering(width: Int32(fixture.dimensions.width),
                                                height: Int32(fixture.dimensions.height)))
        }
    }

    @Test
    func missingKeyFrameStillExpiresTheRecoveryDeadline() async throws {
        let fixture = try presentationFixture(width: 320, height: 180)
        let layer = AVSampleBufferDisplayLayer()
        let renderer = GlassyStreamVideoRenderer()
        var failures: [String] = []
        renderer.onError = { failures.append($0.localizedDescription) }
        renderer.attach(to: layer)
        defer { renderer.detach(from: layer); renderer.reset() }
        let consume = renderer.makeMediaConsumer()
        renderer.mediaQueue.sync { _ = consume(.videoConfiguration(fixture.configuration)) }
        try await Task.sleep(for: .milliseconds(5_300))
        #expect(!layer.isReadyForDisplay)
        #expect(!renderer.isDisplayingVideo)
        #expect(failures.count == 1)
        #expect(failures.first?.contains("Video recovery timed out") == true)
    }

    @Test(arguments: [false, true])
    func retainedImageCannotHideMissingOrInvalidRecoveryFrame(invalidIDR: Bool) async throws {
        let fixture = try presentationFixture(width: 320, height: 180)
        let surface = try PresentationSurface()
        defer { surface.close() }
        var failures: [String] = []
        surface.renderer.onError = { failures.append($0.localizedDescription) }
        let consume = surface.renderer.makeMediaConsumer()
        surface.renderer.mediaQueue.sync {
            _ = consume(.videoConfiguration(fixture.configuration))
            _ = consume(.videoAccessUnit(fixture.frame))
        }
        for _ in 0..<100 {
            if surface.layer.isReadyForDisplay { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(surface.layer.isReadyForDisplay)
        surface.renderer.mediaQueue.sync {
            _ = consume(.videoDiscontinuity)
            // A dependent frame is rejected before decode; an invalid IDR has
            // a legal AVCC boundary but cannot produce a decoded picture.
            _ = consume(.videoAccessUnit(.init(
                data: invalidIDR ? Data([0, 0, 0, 1, 0x65]) : fixture.frame.data,
                presentationTime: 1, duration: 1.0 / 30, isKeyFrame: invalidIDR
            )))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(surface.layer.sampleBufferRenderer.displayedPixelBuffer() != nil)
        #expect(!surface.layer.isReadyForDisplay)
        #expect(surface.renderer.isDisplayingVideo)
        try await Task.sleep(for: .milliseconds(5_300))
        #expect(failures.contains { $0.contains("Video recovery timed out") })
    }

    @Test
    func nativeDecoderPreservesHealthySixteenFrameBurst() async throws {
        let fixture = try presentationFixture(width: 1920, height: 1080, frameCount: 16)
        #expect(fixture.frames.count == 16)
        #expect(fixture.frames.first?.isKeyFrame == true)
        #expect(fixture.frames.dropFirst().allSatisfy { !$0.isKeyFrame })
        let surface = try PresentationSurface()
        defer { surface.close() }
        var requests = 0
        surface.renderer.onKeyFrameNeeded = { requests += 1 }
        let consume = surface.renderer.makeMediaConsumer()
        surface.renderer.mediaQueue.sync {
            _ = consume(.videoConfiguration(fixture.configuration))
            for frame in fixture.frames { _ = consume(.videoAccessUnit(frame)) }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(surface.layer.isReadyForDisplay)
        #expect(surface.renderer.droppedFrameCount == 0)
        #expect(requests == 0, "A brief decoder backlog must preserve the dependent frame chain")
    }
}

private struct PresentationFixture {
    let configuration: GlassyStreamVideoConfiguration
    let frames: [GlassyStreamVideoAccessUnit]
    let dimensions: CGSize
    var frame: GlassyStreamVideoAccessUnit { frames[0] }
}

@MainActor
private final class PresentationSurface {
    let window: UIWindow
    let layer = AVSampleBufferDisplayLayer()
    let renderer = GlassyStreamVideoRenderer()
    init() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 480, height: 320)
        window.rootViewController = UIViewController()
        window.isHidden = false
        layer.frame = window.bounds
        window.rootViewController?.view.layer.addSublayer(layer)
        renderer.attach(to: layer)
    }
    func close() {
        renderer.detach(from: layer)
        renderer.reset()
        layer.removeFromSuperlayer()
        window.isHidden = true
    }
}

private final class PresentationSampleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var result: [CMSampleBuffer] = []
    func accept(_ sample: CMSampleBuffer) { lock.withLock { result.append(sample) } }
    var samples: [CMSampleBuffer] { lock.withLock { result } }
}

private func presentationFixture(width: Int, height: Int, frameCount: Int = 1) throws -> PresentationFixture {
    let capture = PresentationSampleCapture()
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
        width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
        encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: { context, _, status, _, sample in
            guard status == noErr, let context, let sample else { return }
            Unmanaged<PresentationSampleCapture>.fromOpaque(context).takeUnretainedValue().accept(sample)
        }, refcon: Unmanaged.passUnretained(capture).toOpaque(), compressionSessionOut: &session)
    #expect(status == noErr)
    let encoder = try #require(session)
    defer { VTCompressionSessionInvalidate(encoder) }
    #expect(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue) == noErr)
    #expect(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) == noErr)
    var image: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess)
    let pixels = try #require(image)
    CVPixelBufferLockBaseAddress(pixels, [])
    if let bytes = CVPixelBufferGetBaseAddress(pixels) {
        memset(bytes, 160, CVPixelBufferGetBytesPerRow(pixels) * height)
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    for index in 0..<frameCount {
        #expect(VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixels,
            presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), duration: CMTime(value: 1, timescale: 30),
            frameProperties: index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
            sourceFrameRefcon: nil, infoFlagsOut: nil) == noErr)
    }
    #expect(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid) == noErr)
    let samples = capture.samples
    let sample = try #require(samples.first)
    let description = try #require(CMSampleBufferGetFormatDescription(sample))
    var parameterSets: [Data] = []
    var headerLength: Int32 = 0
    for index in 0..<2 {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        #expect(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index,
            parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: &headerLength) == noErr)
        parameterSets.append(Data(bytes: try #require(pointer), count: size))
    }
    let frames = try samples.map { sample in
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let copyStatus = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        #expect(copyStatus == noErr)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return GlassyStreamVideoAccessUnit(data: data, presentationTime: sample.presentationTimeStamp.seconds,
                                          duration: 1.0 / 30, isKeyFrame: !notSync)
    }
    return PresentationFixture(configuration: .init(nalUnitHeaderLength: Int(headerLength), parameterSets: parameterSets),
        frames: frames,
        dimensions: CGSize(width: width, height: height))
}
