@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import GlassyDesk

struct GlassyStreamVideoRecoveryTests {
    @Test @MainActor
    func unavailableDisplayPausesRealRecoveryDeadlineUntilTheHostResumes() async throws {
        let fixture = try presentationFixture(width: 320, height: 180)
        let renderer = GlassyStreamVideoRenderer()
        let layer = AVSampleBufferDisplayLayer()
        var failures: [GlassyStreamVideoRendererError] = []
        renderer.onError = { failures.append($0) }
        renderer.attach(to: layer)
        defer { renderer.detach(from: layer); renderer.reset() }
        let consume = renderer.makeMediaConsumer()
        renderer.mediaQueue.sync {
            _ = consume(.hostStreamStatus(.init(state: .displayUnavailable,
                                                accessibilityGranted: true, ownsInput: true)))
            _ = consume(.videoConfiguration(fixture.configuration))
            _ = consume(.videoDiscontinuity)
        }
        try await Task.sleep(for: .milliseconds(5_300))
        #expect(failures.isEmpty)
        renderer.mediaQueue.sync {
            _ = consume(.hostStreamStatus(.init(state: .streaming,
                                                accessibilityGranted: true, ownsInput: true)))
        }
        // No video is supplied: once the host resumes, the normal bounded
        // recovery deadline must become active again instead of staying paused.
        try await Task.sleep(for: .milliseconds(5_300))
        #expect(failures.count == 1)
        #expect(failures.first?.localizedDescription.contains("Video recovery timed out") == true)
    }

    @Test
    func repeatedRecoveryRequestsCannotExtendDeadline() throws {
        var recovery = GlassyStreamVideoRecoveryState()
        recovery.setAttached(true)
        recovery.begin()
        let original = try #require(recovery.deadlineToken)
        for _ in 0..<20 { recovery.begin() }
        #expect(recovery.deadlineToken == original)
        #expect(recovery.awaitsPresentation)
        recovery.presentationReady()
        #expect(recovery.deadlineToken == nil)
        #expect(!recovery.awaitsPresentation)
    }

    @Test
    func actionableHostPauseInvalidatesOldDeadlineAndResumeStartsFreshDeadline() throws {
        var recovery = GlassyStreamVideoRecoveryState()
        recovery.setAttached(true)
        recovery.begin()
        let original = try #require(recovery.deadlineToken)
        recovery.setPaused(true)
        #expect(recovery.deadlineToken == nil)
        recovery.begin() // Another drop/decoder notification while host is paused.
        #expect(recovery.deadlineToken == nil)
        #expect(recovery.awaitsPresentation)
        recovery.setPaused(false)
        #expect(try #require(recovery.deadlineToken) != original)
    }

    @Test
    func detachedSurfaceCannotExpireAndReattachmentRetiresPreviousTimer() throws {
        var recovery = GlassyStreamVideoRecoveryState()
        recovery.begin()
        #expect(recovery.deadlineToken == nil)
        recovery.setAttached(true)
        let original = try #require(recovery.deadlineToken)
        recovery.setAttached(false)
        #expect(recovery.deadlineToken == nil)
        recovery.setAttached(true)
        #expect(try #require(recovery.deadlineToken) != original)
    }

    @Test
    func newStreamCannotBeExpiredByOldStreamDeadline() throws {
        var recovery = GlassyStreamVideoRecoveryState()
        recovery.setAttached(true)
        recovery.begin()
        let previous = try #require(recovery.deadlineToken)
        recovery = GlassyStreamVideoRecoveryState()
        recovery.setAttached(true)
        recovery.begin()
        #expect(try #require(recovery.deadlineToken) != previous)
    }

    @Test @MainActor
    func resetDropsOldGenerationBeforeItCanConsumeHostStatus() {
        let renderer = GlassyStreamVideoRenderer()
        let previousConsumer = renderer.makeMediaConsumer()
        renderer.reset()
        let currentConsumer = renderer.makeMediaConsumer()
        let status = GlassyStreamEvent.hostStreamStatus(.init(
            state: .screenPermissionRequired, accessibilityGranted: false, ownsInput: true
        ))
        // Joining the serial worker first applies its pending reset. A stale
        // callback is swallowed completely; the active callback passes status
        // through to the session after updating the worker's pause state.
        let result = renderer.mediaQueue.sync { (previousConsumer(status), currentConsumer(status)) }
        #expect(result.0)
        #expect(!result.1)
        renderer.reset()
    }
}
