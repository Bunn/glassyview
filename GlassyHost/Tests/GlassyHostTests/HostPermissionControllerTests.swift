import Foundation
import Testing
@testable import GlassyHost

@MainActor
private final class PermissionFixture {
    let defaults: UserDefaults
    private let suiteName = "GlassyHostPermissionTests.\(UUID().uuidString)"
    var status = HostPermissionSnapshot(screenRecording: false, accessibility: false)
    var statusError = false
    var captureError = false
    var captureRequests = 0

    static let displays = [CaptureDisplay(id: 1, name: "Main", width: 1920, height: 1080, isMain: true)]

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func controller() -> HostPermissionController {
        HostPermissionController(defaults: defaults, readStatus: {
            if self.statusError { throw TestError.unavailable }
            return self.status
        }, requestDirectAccess: {
            self.captureRequests += 1
            if self.captureError { throw TestError.unavailable }
            return Self.displays
        })
    }

    enum TestError: Error { case unavailable }
}

@Test("Permission refresh observes grants and revocation without requesting capture")
@MainActor
func permissionsRefreshWithoutRestart() async {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let controller = fixture.controller()
    await controller.refresh()
    #expect(controller.screenRecordingAuthorization == .denied)

    fixture.status = .init(screenRecording: true, accessibility: true)
    await controller.refresh()
    #expect(controller.screenRecordingAuthorization == .granted)
    #expect(controller.accessibilityAuthorization == .granted)
    #expect(!controller.canCaptureScreen)
    #expect(fixture.captureRequests == 0)

    #expect(await controller.confirmDirectScreenAccess() == PermissionFixture.displays)
    #expect(controller.canCaptureScreen)
    fixture.status = .init(screenRecording: false, accessibility: false)
    await controller.refresh()
    #expect(controller.screenRecordingAuthorization == .denied)
    #expect(controller.accessibilityAuthorization == .denied)
    #expect(!controller.canCaptureScreen)
    #expect(!fixture.defaults.bool(forKey: HostPermissionController.confirmationKey))

    fixture.status = .init(screenRecording: true, accessibility: true)
    await controller.refresh()
    #expect(!controller.canCaptureScreen)
    #expect(fixture.captureRequests == 1)
}

@Test("Direct screen confirmation waits for Screen Recording permission")
@MainActor
func directScreenAccessRequiresScreenRecording() async {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let controller = fixture.controller()
    #expect(await controller.confirmDirectScreenAccess() == nil)
    #expect(fixture.captureRequests == 0)
    #expect(!controller.hasConfirmedDirectScreenAccess)
    #expect(controller.errorMessage != nil)
}

@Test("A declined direct-access check can be retried without restarting")
@MainActor
func directScreenAccessRetriesAfterDenial() async {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    fixture.status = .init(screenRecording: true, accessibility: true)
    fixture.captureError = true
    let controller = fixture.controller()
    #expect(await controller.confirmDirectScreenAccess() == nil)
    #expect(!controller.canCaptureScreen)
    #expect(!controller.isConfirmingScreenAccess)

    fixture.captureError = false
    #expect(await controller.confirmDirectScreenAccess() == PermissionFixture.displays)
    #expect(controller.canCaptureScreen)
    #expect(controller.errorMessage == nil)
    #expect(fixture.captureRequests == 2)
}

@Test("Direct-access completion survives relaunch but does not override revoked system access")
@MainActor
func directScreenAccessPersistence() async {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    fixture.status = .init(screenRecording: true, accessibility: true)
    let first = fixture.controller()
    _ = await first.confirmDirectScreenAccess()

    let relaunched = fixture.controller()
    #expect(!relaunched.canCaptureScreen)
    await relaunched.refresh()
    #expect(relaunched.canCaptureScreen)
    #expect(fixture.captureRequests == 1)

    fixture.status = .init(screenRecording: false, accessibility: true)
    let revoked = fixture.controller()
    await revoked.refresh()
    #expect(!revoked.canCaptureScreen)
    #expect(!revoked.hasConfirmedDirectScreenAccess)
}

@Test("A failed status check cannot claim access and remains retryable")
@MainActor
func permissionStatusFailure() async {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    fixture.statusError = true
    let controller = fixture.controller()
    await controller.refresh()
    #expect(controller.screenRecordingAuthorization == .unknown)
    #expect(!controller.canCaptureScreen)
    #expect(controller.errorMessage != nil)
    #expect(!controller.isRefreshing)

    fixture.statusError = false
    fixture.status = .init(screenRecording: true, accessibility: true)
    await controller.refresh()
    #expect(controller.screenRecordingAuthorization == .granted)
    #expect(controller.errorMessage == nil)
    #expect(fixture.captureRequests == 0)
}

@Test("Repeated confirmation clicks cannot open overlapping capture checks")
@MainActor
func directScreenAccessIsSingleFlight() async {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let started = AsyncStream<Void>.makeStream()
    var completion: CheckedContinuation<[CaptureDisplay], Never>?
    var requests = 0
    let controller = HostPermissionController(defaults: fixture.defaults, readStatus: {
        .init(screenRecording: true, accessibility: true)
    }, requestDirectAccess: {
        requests += 1
        return await withCheckedContinuation {
            completion = $0
            started.continuation.yield(())
        }
    })
    let pending = Task { await controller.confirmDirectScreenAccess() }
    var iterator = started.stream.makeAsyncIterator()
    await iterator.next()
    #expect(await controller.confirmDirectScreenAccess() == nil)
    #expect(requests == 1)
    completion?.resume(returning: PermissionFixture.displays)
    #expect(await pending.value == PermissionFixture.displays)
    #expect(controller.canCaptureScreen)
}

@Test("Revocation while a confirmation is pending wins over its late completion")
@MainActor
func revocationWinsOverPendingConfirmation() async {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    fixture.status = .init(screenRecording: true, accessibility: true)
    let started = AsyncStream<Void>.makeStream()
    var completion: CheckedContinuation<[CaptureDisplay], Never>?
    let controller = HostPermissionController(defaults: fixture.defaults, readStatus: {
        fixture.status
    }, requestDirectAccess: {
        await withCheckedContinuation {
            completion = $0
            started.continuation.yield(())
        }
    })
    let pending = Task { await controller.confirmDirectScreenAccess() }
    var iterator = started.stream.makeAsyncIterator()
    await iterator.next()
    fixture.status = .init(screenRecording: false, accessibility: true)
    await controller.refresh()
    completion?.resume(returning: PermissionFixture.displays)
    #expect(await pending.value == nil)
    #expect(!controller.canCaptureScreen)
    #expect(!fixture.defaults.bool(forKey: HostPermissionController.confirmationKey))
}

@Test("A focus change during a status check triggers a fresh trailing check")
@MainActor
func overlappingPermissionRefreshesReadLatestStatus() async {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let firstStarted = AsyncStream<Void>.makeStream()
    let secondStarted = AsyncStream<Void>.makeStream()
    var completion: CheckedContinuation<HostPermissionSnapshot, Never>?
    var reads = 0
    let controller = HostPermissionController(defaults: fixture.defaults, readStatus: {
        reads += 1
        if reads == 1 {
            return await withCheckedContinuation {
                completion = $0
                firstStarted.continuation.yield(())
            }
        }
        return .init(screenRecording: true, accessibility: true)
    }, requestDirectAccess: { [] })
    let first = Task { await controller.refresh() }
    var firstIterator = firstStarted.stream.makeAsyncIterator()
    await firstIterator.next()
    let second = Task {
        secondStarted.continuation.yield(())
        return await controller.refresh()
    }
    var secondIterator = secondStarted.stream.makeAsyncIterator()
    await secondIterator.next()
    completion?.resume(returning: .init(screenRecording: false, accessibility: false))
    _ = await first.value
    _ = await second.value
    #expect(reads == 2)
    #expect(controller.screenRecordingAuthorization == .granted)
    #expect(controller.accessibilityAuthorization == .granted)
}
