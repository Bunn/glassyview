import Testing
@testable import GlassyHost

@Test("A second capture generation delivers frames after the first consumer is cancelled")
func frameRelayRestartsAfterConsumerCancellation() async {
    let firstCapture = CaptureFrameRelay<Int>()
    let firstConsumer = Task {
        var iterator = firstCapture.stream.makeAsyncIterator()
        return await iterator.next()
    }

    firstConsumer.cancel()
    #expect(await firstConsumer.value == nil)

    let firstStreamWasTerminated: Bool
    switch firstCapture.yield(1) {
    case .terminated:
        firstStreamWasTerminated = true
    case .enqueued, .dropped:
        firstStreamWasTerminated = false
    @unknown default:
        firstStreamWasTerminated = false
    }
    #expect(firstStreamWasTerminated)
    firstCapture.finish()

    let secondCapture = CaptureFrameRelay<Int>()
    let acceptedFrame: Bool
    switch secondCapture.yield(42) {
    case .enqueued:
        acceptedFrame = true
    case .dropped, .terminated:
        acceptedFrame = false
    @unknown default:
        acceptedFrame = false
    }
    #expect(acceptedFrame)

    var secondIterator = secondCapture.stream.makeAsyncIterator()
    #expect(await secondIterator.next() == 42)
    secondCapture.finish()
}

@Test("A blank or suspended display reports unavailability once and recovers on a real frame")
func displayAvailabilityRecoversAfterSleep() {
    var availability = CaptureDisplayAvailability()
    #expect(availability.update(.complete) == nil)
    #expect(availability.update(.idle) == nil)
    #expect(availability.update(.blank) == false)
    #expect(availability.update(.blank) == nil)
    #expect(availability.update(.suspended) == nil)
    #expect(availability.update(.idle) == nil)
    #expect(availability.update(.started) == nil)
    #expect(availability.update(.complete) == true)
    #expect(availability.update(.complete) == nil)
    #expect(availability.update(.suspended) == false)
    #expect(availability.update(.complete) == true)
}
