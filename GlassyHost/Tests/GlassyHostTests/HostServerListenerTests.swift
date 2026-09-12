import Foundation
import Network
import Testing
@testable import GlassyHost

@Test("Glassy Desk uses a stable private direct-connect port")
func stableDefaultHostPort() {
    #expect(HostProtocol.defaultPort == 51_515)
    #expect(HostProtocol.defaultPort >= 49_152)
}

@Test("A listener port conflict explains how to recover")
func listenerPortConflictMessage() {
    let message = HostServer.listenerFailureMessage(
        for: .posix(.EADDRINUSE)
    )

    #expect(message.contains("TCP port 51515 is already in use"))
    #expect(message.contains("Quit the other Glassy Desk instance or app"))
    #expect(message.contains("retry automatically every 30 seconds"))
}

@Test("Listener recovery uses capped backoff and slows port conflicts")
func listenerRetryBackoff() {
    let transientError = NWError.posix(.ENETDOWN)
    let transientDelays = (0...7).map {
        HostListenerRetryPolicy.delay(after: transientError, attempt: $0)
    }

    #expect(transientDelays == [1, 2, 4, 8, 15, 30, 30, 30])
    #expect(
        HostListenerRetryPolicy.delay(
            after: .posix(.EADDRINUSE),
            attempt: 0
        ) == 30
    )
    #expect(
        HostListenerRetryPolicy.delay(
            after: .posix(.EADDRINUSE),
            attempt: 100
        ) == 30
    )
}

@Test("System wake recreates the listener without changing pairing identity or reopening disabled access")
func listenerRestartsAfterSystemWake() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let access = HostDeviceAccessStore(fileURL: directory.appendingPathComponent("devices.json"))
    let events = AsyncStream<HostServer.Status>.makeStream()
    let recorder = WakeListenerStatusRecorder()
    let server = HostServer(serviceName: "GlassyHost Wake Test", port: 0, deviceAccessStore: access)
    defer { server.stop(); events.continuation.finish() }
    let now = Date()
    server.start(pairingSecret: Data(repeating: 42, count: 32), onStatusChange: {
        recorder.append($0)
        events.continuation.yield($0)
    })
    #expect(try await nextListeningPort(in: events.stream) > 0)
    let code = try #require(server.currentPairingCode(at: now)?.value)

    server.restartAfterSystemWake()
    #expect(try await nextListeningPort(in: events.stream) > 0)
    #expect(server.currentPairingCode(at: now)?.value == code)
    #expect(recorder.listeningCount == 2)

    try await server.setAllowsConnections(false)
    let beforeWake = recorder.listeningCount
    server.restartAfterSystemWake()
    // clearVideoState completes on the same queue, after the wake request.
    await server.clearVideoState()
    #expect(!server.allowsConnections)
    #expect(recorder.listeningCount == beforeWake)
    #expect(recorder.lastIsStopped)
}

private func nextListeningPort(in events: AsyncStream<HostServer.Status>) async throws -> UInt16 {
    try await withThrowingTaskGroup(of: UInt16.self) { group in
        group.addTask {
            for await event in events {
                if case .listening(let port) = event { return port }
                if case .failed(let message) = event { throw WakeListenerError.failed(message) }
            }
            throw WakeListenerError.timedOut
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw WakeListenerError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private enum WakeListenerError: Error {
    case timedOut
    case failed(String)
}

private final class WakeListenerStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HostServer.Status] = []
    func append(_ event: HostServer.Status) { lock.withLock { events.append(event) } }
    var listeningCount: Int {
        lock.withLock { events.filter { if case .listening = $0 { return true }; return false }.count }
    }
    var lastIsStopped: Bool {
        lock.withLock { if case .stopped? = events.last { return true }; return false }
    }
}
