import Foundation
import IOKit.pwr_mgt
import Testing
@testable import GlassyHost

@Test("Only authenticated viewers wake the display and idle sleep resumes after the final disconnect")
@MainActor
func remoteSessionPowerFollowsAuthenticatedViewers() {
    let recorder = PowerAssertionRecorder()
    let service = recorder.service()
    service.update(authenticatedClientCount: 0, allowsConnections: true)
    service.wakeDisplay()
    service.update(authenticatedClientCount: 1, allowsConnections: false)
    #expect(recorder.events.isEmpty)

    service.update(authenticatedClientCount: 1, allowsConnections: true)
    #expect(recorder.events == ["wake:0", "hold"])
    service.update(authenticatedClientCount: 2, allowsConnections: true)
    service.update(authenticatedClientCount: 1, allowsConnections: true)
    #expect(recorder.events == ["wake:0", "hold"])

    service.wakeDisplay()
    #expect(recorder.events.last == "wake:200")
    service.update(authenticatedClientCount: 0, allowsConnections: true)
    #expect(recorder.events.suffix(2) == ["release:100", "release:200"])
    let finishedEvents = recorder.events
    service.update(authenticatedClientCount: 0, allowsConnections: true)
    service.wakeDisplay()
    #expect(recorder.events == finishedEvents)

    service.update(authenticatedClientCount: 1, allowsConnections: true)
    #expect(recorder.events.suffix(2) == ["wake:0", "hold"])
    service.update(authenticatedClientCount: 1, allowsConnections: false)
    #expect(recorder.events.suffix(2) == ["release:100", "release:200"])
}

@Test("Power assertion failures are retryable and shutdown releases every acquired assertion")
@MainActor
func remoteSessionPowerFailureAndShutdown() {
    let recorder = PowerAssertionRecorder()
    recorder.failNextHold = true
    var service: HostRemoteSessionPowerService? = recorder.service()
    service?.update(authenticatedClientCount: 1, allowsConnections: true)
    service?.update(authenticatedClientCount: 1, allowsConnections: true)
    #expect(recorder.events == ["wake:0", "hold", "hold"])
    service = nil
    #expect(recorder.events.suffix(2) == ["release:100", "release:200"])
}

private final class PowerAssertionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var failNextHold = false
    var events: [String] { lock.withLock { storage } }

    @MainActor
    func service() -> HostRemoteSessionPowerService {
        HostRemoteSessionPowerService(createDisplayAssertion: {
            self.lock.withLock {
                self.storage.append("hold")
                if self.failNextHold {
                    self.failNextHold = false
                    return nil
                }
                return 100
            }
        }, declareRemoteActivity: { assertion in
            self.lock.withLock { self.storage.append("wake:\(assertion)") }
            assertion = 200
        }, releaseAssertion: { assertion in
            self.lock.withLock { self.storage.append("release:\(assertion)") }
        })
    }
}
