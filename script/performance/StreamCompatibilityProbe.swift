import CryptoKit
import Foundation
import Network

private final class CompatibilityState: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCount = 0
    private var configurationCount = 0
    private var pong = false
    private var inputs: [String] = []
    private var failures: [String] = []
    private var statusCount = 0
    func event(_ event: GlassyStreamEvent) {
        lock.withLock {
            switch event {
            case .videoAccessUnit: frameCount += 1
            case .videoConfiguration: configurationCount += 1
            case .pong: pong = true
            case .hostStreamStatus: statusCount += 1
            default: break
            }
        }
    }
    func input(_ input: HostProtocol.RemoteInputEvent) {
        if case .text(let text) = input { lock.withLock { inputs.append(text.text) } }
    }
    func failure(_ error: Error) { lock.withLock { failures.append(error.localizedDescription) } }
    var report: [String: Any] { lock.withLock {
        ["frames_received": frameCount, "configurations_received": configurationCount, "pong_received": pong, "input_received": inputs,
         "errors": failures, "unnegotiated_status_messages": statusCount,
         "passed": frameCount > 0 && configurationCount == 1 && pong && inputs == ["compatibility"] && failures.isEmpty && statusCount == 0]
    } }
}

private struct CompatibilityCredentialStore: GlassyStreamResumeCredentialStoring {
    func credential(savedMachineID: UUID, hostIdentifier: Data) throws -> GlassyStreamResumeCredential? { nil }
    func save(_ credential: GlassyStreamResumeCredential, savedMachineID: UUID, hostIdentifier: Data) throws {}
    func removeCredential(savedMachineID: UUID, hostIdentifier: Data) throws {}
}

@main private enum StreamCompatibilityProbe {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        let state = CompatibilityState()
        let hostStatus = AsyncStream<HostServer.Status>.makeStream()
        let host = HostServer(serviceName: "Glassy Compatibility", port: 0,
                              deviceAccessStore: HostDeviceAccessStore(fileURL: directory.appendingPathComponent("devices")))
        let secret = Data(repeating: 0x53, count: 32)
        host.setRemoteInputHandler { state.input($0) }
        host.start(pairingSecret: secret, onStatusChange: { hostStatus.continuation.yield($0) })
        defer { host.stop(); hostStatus.continuation.finish() }
        var port: UInt16?
        for await status in hostStatus.stream {
            if case .listening(let value) = status { port = value; break }
            if case .failed(let error) = status { throw CompatibilityError(message: error) }
        }
        guard let port, let code = host.currentPairingCode()?.value else { throw CompatibilityError(message: "No host") }
        let authentication = AsyncStream<Bool>.makeStream()
        let client = GlassyStreamClient(credentialStore: CompatibilityCredentialStore())
        defer { client.disconnect(); authentication.continuation.finish() }
        client.connect(configuration: .init(endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!),
                                            savedMachineID: UUID(), bootstrapCredential: .oneTimeCode(code),
                                            expectedHostIdentifier: HostServer.makeHostIdentifier(from: secret)),
                       callbackQueue: .global(qos: .userInitiated), callbacks: .init(onEvent: { event in
            state.event(event)
            if case .authenticated = event { authentication.continuation.yield(true) }
        }, onCompletion: { result in
            if case .failure(let error) = result { state.failure(error); authentication.continuation.yield(false) }
        }))
        var iterator = authentication.stream.makeAsyncIterator()
        guard await iterator.next() == true else { throw CompatibilityError(message: "Authentication failed") }
        client.sendTextInput("compatibility")
        host.broadcastCodecConfiguration(parameterSets: [Data([0x67, 0x42]), Data([0x68, 1])], nalUnitHeaderLength: 4)
        for index in 0..<20 {
            host.broadcastVideoAccessUnit(Data(repeating: 0x55, count: 256),
                                          presentationTimeSeconds: ProcessInfo.processInfo.systemUptime,
                                          durationSeconds: 0.02, isKeyFrame: index % 5 == 0)
            try await Task.sleep(for: .milliseconds(20))
        }
        client.sendPing(Data([0x42]))
        try await Task.sleep(for: .milliseconds(300))
        var report = state.report
        report["mode"] = mode
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        guard report["passed"] as? Bool == true else { throw CompatibilityError(message: "Compatibility assertions failed") }
    }
}
private struct CompatibilityError: Error { let message: String }
