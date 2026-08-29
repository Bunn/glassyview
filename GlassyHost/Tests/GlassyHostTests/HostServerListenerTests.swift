import Network
import Testing
@testable import GlassyHost

@Test("Glassy Host uses a stable private direct-connect port")
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
    #expect(message.contains("Quit the other Glassy Host instance or app"))
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
