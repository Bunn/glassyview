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

}

private struct PresentationFixture {
    let configuration: GlassyStreamVideoConfiguration
    let frame: GlassyStreamVideoAccessUnit
    let dimensions: CGSize
}

private final class PresentationSampleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var result: CMSampleBuffer?
    func accept(_ sample: CMSampleBuffer) { lock.withLock { result = sample } }
    var sample: CMSampleBuffer? { lock.withLock { result } }
}

private func presentationFixture(width: Int, height: Int) throws -> PresentationFixture {
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
    #expect(VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixels,
        presentationTimeStamp: .zero, duration: CMTime(value: 1, timescale: 30),
        frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
        sourceFrameRefcon: nil, infoFlagsOut: nil) == noErr)
    #expect(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid) == noErr)
    let sample = try #require(capture.sample)
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
    let block = try #require(CMSampleBufferGetDataBuffer(sample))
    var data = Data(count: CMBlockBufferGetDataLength(block))
    let copyStatus = data.withUnsafeMutableBytes { bytes in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
    }
    #expect(copyStatus == noErr)
    return PresentationFixture(configuration: .init(nalUnitHeaderLength: Int(headerLength), parameterSets: parameterSets),
        frame: .init(data: data, presentationTime: 0, duration: 1.0 / 30, isKeyFrame: true),
        dimensions: CGSize(width: width, height: height))
}
