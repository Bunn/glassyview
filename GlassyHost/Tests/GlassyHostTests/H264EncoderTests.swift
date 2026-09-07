import Foundation
import CoreMedia
import CoreVideo
import Testing
import VideoToolbox
@testable import GlassyHost

@Test("Unsupported optional encoder properties use the encoder default")
func unsupportedOptionalEncoderPropertyFallsBack() {
    #expect(
        H264CompressionPropertyPolicy.shouldIgnoreFailure(
            status: kVTPropertyNotSupportedErr,
            requirement: .optional
        )
    )
}

@Test("Unsupported required encoder properties remain fatal")
func unsupportedRequiredEncoderPropertyFails() {
    #expect(
        !H264CompressionPropertyPolicy.shouldIgnoreFailure(
            status: kVTPropertyNotSupportedErr,
            requirement: .required
        )
    )
}

@Test("Optional encoder properties surface genuine configuration errors")
func invalidOptionalEncoderPropertyFails() {
    #expect(
        !H264CompressionPropertyPolicy.shouldIgnoreFailure(
            status: kVTParameterErr,
            requirement: .optional
        )
    )
}

private final class EncoderProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var units: [H264AccessUnit] = []
    private var failures: [String] = []
    private var configurations: [H264CodecConfiguration] = []
    func accept(_ output: H264EncoderOutput) {
        switch output {
        case .accessUnit(let unit): lock.withLock { units.append(unit) }
        case .codecConfiguration(let configuration): lock.withLock { configurations.append(configuration) }
        }
    }
    func fail(_ error: H264EncoderError) { lock.withLock { failures.append(error.localizedDescription) } }
    var frames: [H264AccessUnit] { lock.withLock { units } }
    var errors: [String] { lock.withLock { failures } }
    var configurationCount: Int { lock.withLock { configurations.count } }
}

@Test("Idle recovery reencodes a retained capture once, with fresh timing, then stops", arguments: [960, 640, 320])
func encoderIdleRecoveryIsBounded(width: Int) async throws {
    let output = EncoderProbeOutput()
    let encoder = H264Encoder(configuration: .init(expectedFrameRate: 8, averageBitRate: 350_000),
                              outputHandler: { output.accept($0) }, errorHandler: { output.fail($0) })
    let buffer = try makeEncoderProbeBuffer(width: width, height: width * 9 / 16, noise: true)
    try await encoder.encode(.init(pixelBuffer: buffer,
                                   presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                   duration: CMTime(value: 1, timescale: 8)))
    for _ in 0..<40 {
        if !output.frames.isEmpty { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let before = try #require(output.frames.last)
    for _ in 0..<20 { encoder.requestKeyFrame() }
    try await Task.sleep(for: .milliseconds(400))
    let recovered = output.frames
    #expect(recovered.count >= 2)
    #expect(recovered.count <= 3)
    #expect(recovered.last?.isKeyFrame == true)
    #expect(try #require(recovered.last).presentationTimeSeconds > before.presentationTimeSeconds)
    // A high-entropy first IDR may exceed a nominal per-frame bitrate budget.
    // Record its real size; HostServer admits one IDR and bounds receiver credit.
    print("Encoder \(width)px noise keyframe bytes: \(recovered.filter(\.isKeyFrame).map { $0.data.count })")
    #expect(recovered.allSatisfy { $0.data.count < HostProtocol.maximumPayloadLength - 16 })
    try await encoder.updateConfiguration(.init(expectedFrameRate: 8, averageBitRate: 350_000,
                                                maximumWidth: 320, maximumHeight: 180))
    try await Task.sleep(for: .milliseconds(400))
    #expect(output.frames.last?.encodedWidth == 320)
    print("Retained \(width)→320px recovery bytes: \(output.frames.last?.data.count ?? 0)")
    await encoder.finish()
    let completedCount = output.frames.count
    encoder.requestKeyFrame()
    try await Task.sleep(for: .milliseconds(100))
    #expect(output.frames.count == completedCount)
    #expect(output.errors.isEmpty)
}

private func makeEncoderProbeBuffer(width: Int, height: Int, noise: Bool) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    #expect(result == kCVReturnSuccess)
    let pixelBuffer = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    var random: UInt32 = 0x53AC9127
    for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
        guard let raw = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let count = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        for index in 0..<count {
            random = random &* 1_664_525 &+ 1_013_904_223
            bytes[index] = noise ? UInt8(truncatingIfNeeded: random >> 24) : (plane == 0 ? 64 : 128)
        }
    }
    return pixelBuffer
}

@Test("Bitrate and cadence updates do not force idle IDRs or reset the dependency chain")
func encoderRateChangesDoNotForceRecovery() async throws {
    let output = EncoderProbeOutput()
    let encoder = H264Encoder(configuration: .init(expectedFrameRate: 30, averageBitRate: 5_000_000,
                                                  maximumWidth: 1280, maximumHeight: 720),
                              outputHandler: { output.accept($0) }, errorHandler: { output.fail($0) })
    let buffer = try makeEncoderProbeBuffer(width: 640, height: 360, noise: false)
    try await encoder.encode(.init(pixelBuffer: buffer, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                   duration: CMTime(value: 1, timescale: 30)))
    for _ in 0..<40 {
        if !output.frames.isEmpty { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(output.frames.count == 1)
    for rate in [6_000_000, 7_000_000, 8_000_000] {
        try await encoder.updateConfiguration(.init(expectedFrameRate: 60, averageBitRate: rate,
                                                    maximumWidth: 1280, maximumHeight: 720))
    }
    try await Task.sleep(for: .milliseconds(400))
    #expect(output.frames.count == 1)
    #expect(output.errors.isEmpty)
    await encoder.finish()
}

@Test("Recovery IDRs and rate changes do not repeatedly publish decoder configuration")
func repeatedRecoveryKeepsDecoderConfiguration() async throws {
    let output = EncoderProbeOutput()
    let encoder = H264Encoder(configuration: .init(expectedFrameRate: 30, averageBitRate: 5_000_000,
                                                  maximumWidth: 1280, maximumHeight: 720),
                              outputHandler: { output.accept($0) }, errorHandler: { output.fail($0) })
    let buffer = try makeEncoderProbeBuffer(width: 640, height: 360, noise: true)
    try await encoder.encode(.init(pixelBuffer: buffer, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                   duration: CMTime(value: 1, timescale: 30)))
    for _ in 0..<40 {
        if !output.frames.isEmpty { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    for (rate, fps) in [(6_000_000, 30), (8_000_000, 60), (12_000_000, 60)] {
        try await encoder.updateConfiguration(.init(expectedFrameRate: fps, averageBitRate: rate,
                                                    maximumWidth: 1280, maximumHeight: 720))
        encoder.requestKeyFrame()
        try await Task.sleep(for: .milliseconds(350))
    }
    await encoder.finish()
    #expect(output.frames.filter(\.isKeyFrame).count == 4)
    #expect(output.configurationCount == 1)
    #expect(output.errors.isEmpty)
}
