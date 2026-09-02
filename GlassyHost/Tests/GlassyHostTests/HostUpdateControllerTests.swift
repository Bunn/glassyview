import Foundation
import Observation
import Testing
@testable import GlassyHost

@MainActor
private final class TestHostUpdateDriver: HostUpdateDriver {
    var canCheckForUpdates = false {
        didSet { onCanCheckForUpdatesChange?(canCheckForUpdates) }
    }
    var onCanCheckForUpdatesChange: (@MainActor (Bool) -> Void)?
    var startupFailure: (any Error)?
    private(set) var startCount = 0
    private(set) var checkCount = 0

    func start() throws {
        startCount += 1
        if let startupFailure {
            throw startupFailure
        }
    }

    func checkForUpdates() {
        checkCount += 1
    }
}

private struct TestHostUpdateStartupError: LocalizedError {
    var errorDescription: String? { "Test updater could not start." }
}

@MainActor
@Observable
private final class TestHostUpdateSessions {
    var hasActiveSessions = true
}

private func testHostUpdateConfiguration() throws -> HostUpdateConfiguration {
    try #require(HostUpdateConfiguration(infoDictionary: [
        "SUFeedURL": "https://downloads.example.com/appcast.xml",
        "SUPublicEDKey": Data(repeating: 0xA1, count: 32).base64EncodedString(),
    ]))
}

@Test("The updater exposes Sparkle's postponement and cleanup delegate selectors")
@MainActor
func hostUpdateDelegateSelectorsAreAvailable() {
    let controller = HostUpdateController(configuration: nil)
    for selector in [
        "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
        "updater:didAbortWithError:",
        "updater:didFinishUpdateCycleForUpdateCheck:error:",
    ] {
        #expect(controller.responds(to: NSSelectorFromString(selector)))
    }
}

@Test("An unconfigured updater never creates or starts a Sparkle driver")
@MainActor
func unconfiguredHostUpdaterStaysInactive() {
    let driver = TestHostUpdateDriver()
    var factoryCount = 0
    let controller = HostUpdateController(configuration: nil, makeDriver: { _ in
        factoryCount += 1
        return driver
    })

    controller.startIfConfigured()
    controller.startIfConfigured()
    controller.checkForUpdates()

    #expect(!controller.isConfigured)
    #expect(!controller.canCheckForUpdates)
    #expect(controller.startupError == nil)
    #expect(factoryCount == 0)
    #expect(driver.startCount == 0)
    #expect(driver.checkCount == 0)
}

@Test("A configured updater starts once and stays disabled before startup")
@MainActor
func configuredHostUpdaterStartsOnce() throws {
    let driver = TestHostUpdateDriver()
    driver.canCheckForUpdates = true
    var factoryCount = 0
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        makeDriver: { _ in
            factoryCount += 1
            return driver
        }
    )

    driver.canCheckForUpdates = false
    driver.canCheckForUpdates = true
    #expect(controller.isConfigured)
    #expect(!controller.canCheckForUpdates)
    #expect(driver.startCount == 0)
    controller.checkForUpdates()
    #expect(driver.checkCount == 0)

    controller.startIfConfigured()
    controller.startIfConfigured()

    #expect(factoryCount == 1)
    #expect(driver.startCount == 1)
    #expect(controller.canCheckForUpdates)
    #expect(controller.startupError == nil)
}

@Test("The update menu follows driver availability and guards manual checks")
@MainActor
func hostUpdaterTracksDriverAvailability() throws {
    let driver = TestHostUpdateDriver()
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        makeDriver: { _ in driver }
    )
    controller.startIfConfigured()

    #expect(!controller.canCheckForUpdates)
    controller.checkForUpdates()
    #expect(driver.checkCount == 0)

    driver.canCheckForUpdates = true
    #expect(controller.canCheckForUpdates)
    controller.checkForUpdates()
    #expect(driver.checkCount == 1)

    driver.canCheckForUpdates = false
    #expect(!controller.canCheckForUpdates)
    controller.checkForUpdates()
    #expect(driver.checkCount == 1)

    driver.canCheckForUpdates = true
    #expect(controller.canCheckForUpdates)
    controller.checkForUpdates()
    #expect(driver.checkCount == 2)
}

@Test("A startup failure leaves the updater disabled even after availability changes")
@MainActor
func hostUpdaterStartupFailureDisablesChecks() throws {
    let driver = TestHostUpdateDriver()
    driver.canCheckForUpdates = true
    driver.startupFailure = TestHostUpdateStartupError()
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        makeDriver: { _ in driver }
    )

    controller.startIfConfigured()

    #expect(controller.isConfigured)
    #expect(!controller.canCheckForUpdates)
    #expect(controller.startupError?.contains("Test updater could not start.") == true)
    driver.canCheckForUpdates = false
    driver.canCheckForUpdates = true
    #expect(!controller.canCheckForUpdates)
    controller.checkForUpdates()
    #expect(driver.startCount == 1)
    #expect(driver.checkCount == 0)
}

@Test("An idle host does not postpone update installation")
@MainActor
func idleHostDoesNotPostponeInstallation() throws {
    let driver = TestHostUpdateDriver()
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        hasActiveSessions: { false },
        makeDriver: { _ in driver }
    )
    var installCount = 0

    let postponed = controller.postponeInstallationIfNeeded { installCount += 1 }

    #expect(!postponed)
    #expect(!controller.isInstallationDeferred)
    controller.resumeInstallationIfPossible()
    #expect(installCount == 0)
}

@Test("Active sessions postpone installation until the host is idle")
@MainActor
func activeHostSessionsDeferInstallation() throws {
    let driver = TestHostUpdateDriver()
    driver.canCheckForUpdates = true
    let sessions = TestHostUpdateSessions()
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        hasActiveSessions: { sessions.hasActiveSessions },
        makeDriver: { _ in driver }
    )
    var installCount = 0
    controller.startIfConfigured()
    #expect(controller.canCheckForUpdates)

    let postponed = controller.postponeInstallationIfNeeded { installCount += 1 }

    #expect(postponed)
    #expect(controller.isInstallationDeferred)
    #expect(!controller.canCheckForUpdates)
    controller.checkForUpdates()
    #expect(driver.checkCount == 0)
    controller.resumeInstallationIfPossible()
    #expect(controller.isInstallationDeferred)
    #expect(installCount == 0)

    sessions.hasActiveSessions = false
    controller.resumeInstallationIfPossible()
    #expect(!controller.isInstallationDeferred)
    #expect(controller.canCheckForUpdates)
    #expect(installCount == 1)
    controller.resumeInstallationIfPossible()
    #expect(installCount == 1)
}

@Test("An observed session disconnect resumes installation without a visible menu")
@MainActor
func observedHostSessionDisconnectResumesInstallation() async throws {
    let driver = TestHostUpdateDriver()
    let sessions = TestHostUpdateSessions()
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        hasActiveSessions: { sessions.hasActiveSessions },
        makeDriver: { _ in driver }
    )
    var installCount = 0
    let postponed = controller.postponeInstallationIfNeeded { installCount += 1 }
    #expect(postponed)
    #expect(controller.isInstallationDeferred)

    sessions.hasActiveSessions = false
    for _ in 0..<20 where installCount == 0 {
        await Task.yield()
    }

    #expect(installCount == 1)
    #expect(!controller.isInstallationDeferred)
    controller.resumeInstallationIfPossible()
    #expect(installCount == 1)
}

@Test("A reconnect before the queued observation callback keeps installation deferred")
@MainActor
func observedHostSessionReconnectKeepsInstallationDeferred() async throws {
    let driver = TestHostUpdateDriver()
    let sessions = TestHostUpdateSessions()
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        hasActiveSessions: { sessions.hasActiveSessions },
        makeDriver: { _ in driver }
    )
    var installCount = 0
    let postponed = controller.postponeInstallationIfNeeded { installCount += 1 }
    #expect(postponed)

    sessions.hasActiveSessions = false
    sessions.hasActiveSessions = true
    for _ in 0..<20 {
        await Task.yield()
    }

    #expect(installCount == 0)
    #expect(controller.isInstallationDeferred)

    sessions.hasActiveSessions = false
    for _ in 0..<20 where installCount == 0 {
        await Task.yield()
    }

    #expect(installCount == 1)
    #expect(!controller.isInstallationDeferred)
}

@Test("Cancellation invalidates an already queued session observation callback")
@MainActor
func canceledHostUpdateIgnoresQueuedSessionDisconnect() async throws {
    let driver = TestHostUpdateDriver()
    let sessions = TestHostUpdateSessions()
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        hasActiveSessions: { sessions.hasActiveSessions },
        makeDriver: { _ in driver }
    )
    var installCount = 0
    let postponed = controller.postponeInstallationIfNeeded { installCount += 1 }
    #expect(postponed)

    sessions.hasActiveSessions = false
    controller.cancelDeferredInstallation()
    for _ in 0..<20 {
        await Task.yield()
    }

    #expect(installCount == 0)
    #expect(!controller.isInstallationDeferred)
    controller.resumeInstallationIfPossible()
    #expect(installCount == 0)
}

@Test("Canceling a deferred installation discards its callback")
@MainActor
func canceledHostUpdateDoesNotResumeInstallation() throws {
    let driver = TestHostUpdateDriver()
    let sessions = TestHostUpdateSessions()
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        hasActiveSessions: { sessions.hasActiveSessions },
        makeDriver: { _ in driver }
    )
    var installCount = 0
    _ = controller.postponeInstallationIfNeeded { installCount += 1 }

    controller.cancelDeferredInstallation()

    #expect(!controller.isInstallationDeferred)
    #expect(installCount == 0)
    sessions.hasActiveSessions = false
    controller.resumeInstallationIfPossible()
    controller.cancelDeferredInstallation()
    #expect(!controller.isInstallationDeferred)
    #expect(installCount == 0)
}

@Test("Installation state is cleared before invoking a reentrant resume callback")
@MainActor
func hostUpdateResumeIsReentrantSafe() throws {
    let driver = TestHostUpdateDriver()
    let sessions = TestHostUpdateSessions()
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        hasActiveSessions: { sessions.hasActiveSessions },
        makeDriver: { _ in driver }
    )
    var installCount = 0
    _ = controller.postponeInstallationIfNeeded {
        installCount += 1
        #expect(!controller.isInstallationDeferred)
        controller.resumeInstallationIfPossible()
    }

    sessions.hasActiveSessions = false
    controller.resumeInstallationIfPossible()

    #expect(installCount == 1)
    #expect(!controller.isInstallationDeferred)
}

@Test("A resumed installation may defer a new installation without losing it")
@MainActor
func reentrantHostUpdatePreservesNewDeferredInstallation() throws {
    let driver = TestHostUpdateDriver()
    let sessions = TestHostUpdateSessions()
    let controller = HostUpdateController(
        configuration: try testHostUpdateConfiguration(),
        hasActiveSessions: { sessions.hasActiveSessions },
        makeDriver: { _ in driver }
    )
    var firstInstallCount = 0
    var secondInstallCount = 0
    _ = controller.postponeInstallationIfNeeded {
        firstInstallCount += 1
        sessions.hasActiveSessions = true
        let postponed = controller.postponeInstallationIfNeeded {
            secondInstallCount += 1
        }
        #expect(postponed)
    }

    sessions.hasActiveSessions = false
    controller.resumeInstallationIfPossible()
    #expect(firstInstallCount == 1)
    #expect(secondInstallCount == 0)
    #expect(controller.isInstallationDeferred)
    controller.resumeInstallationIfPossible()
    #expect(secondInstallCount == 0)

    sessions.hasActiveSessions = false
    controller.resumeInstallationIfPossible()
    #expect(firstInstallCount == 1)
    #expect(secondInstallCount == 1)
    #expect(!controller.isInstallationDeferred)
}
