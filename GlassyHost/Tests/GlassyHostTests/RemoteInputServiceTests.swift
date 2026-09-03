import Foundation
import Testing
@testable import GlassyHost

@Test("Device revocation waits for earlier remote input and its reset to finish")
func remoteInputReleaseIsCompletionBarrier() {
    let inputQueue = DispatchQueue(label: "GlassyHostTests.pending-remote-input")
    let service = RemoteInputService(inputQueue: inputQueue)
    let earlierInputStarted = DispatchSemaphore(value: 0)
    let finishEarlierInput = DispatchSemaphore(value: 0)
    let releaseStarted = DispatchSemaphore(value: 0)
    let releaseCompleted = DispatchSemaphore(value: 0)

    inputQueue.async {
        earlierInputStarted.signal()
        finishEarlierInput.wait()
    }
    #expect(earlierInputStarted.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
        releaseStarted.signal()
        service.releasePressedInput()
        releaseCompleted.signal()
    }
    #expect(releaseStarted.wait(timeout: .now() + 2) == .success)

    // An asynchronous reset would incorrectly report completion while this
    // earlier input is still blocked on its queue.
    let returnedBeforeInputFinished = releaseCompleted.wait(timeout: .now() + 0.05)
    finishEarlierInput.signal()
    #expect(returnedBeforeInputFinished == .timedOut)
    if returnedBeforeInputFinished == .timedOut {
        #expect(releaseCompleted.wait(timeout: .now() + 2) == .success)
    }
}
