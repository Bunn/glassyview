import Foundation
import Network

/// Real encrypted TCP between independently versioned production transports.
/// Capture and OS input are deliberately absent; all credentials are temporary.
@main
private enum ReleasedPeerCompatibilityProbe {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let observed = Observations()
        let credentials = MemoryCredentials()
        let host = HostServer(serviceName: "Released peer compatibility", port: 0,
                              deviceAccessStore: HostDeviceAccessStore(fileURL: directory.appendingPathComponent("devices")))
        let secret = Data(repeating: 0x53, count: 32)
        let hostID = HostServer.makeHostIdentifier(from: secret)
        let savedMachineID = UUID()
        host.setRemoteInputHandler { input in observed.update { $0.inputs.append(input) } }
        host.setStreamQualityHandler { quality in observed.update { $0.qualities.append(quality) } }
        host.start(pairingSecret: secret, onClientCountChange: { count in
            observed.update { $0.clientCount = count }
        }, onStatusChange: { status in
            observed.update {
                if case .listening(let port) = status { $0.port = port }
                if case .failed(let message) = status { $0.errors.append(message) }
            }
        })
        defer { host.stop() }
        try await wait("listener", observed) { $0.port != nil }
        let port = observed.read { $0.port! }
        guard let code = host.currentPairingCode()?.value else { throw Failure(message: "No pairing code") }
        try require(GlassyStreamWire.normalizedPairingCode(code) != nil,
                    "The released client rejects the host's pairing code")
        let client = GlassyStreamClient(credentialStore: credentials)
        defer { client.disconnect() }
        let callbacks = DispatchQueue(label: "glassy.compatibility.callbacks")

        for session in 0..<2 {
            await host.clearVideoState()
            client.connect(configuration: .init(
                endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!),
                savedMachineID: savedMachineID,
                bootstrapCredential: session == 0 ? .oneTimeCode(code) : nil,
                expectedHostIdentifier: hostID
            ), callbackQueue: callbacks, callbacks: .init(onEvent: { event in
                observed.update {
                    switch event {
                    case .authenticated(let authentication): $0.authentications.append(authentication)
                    case .hostStreamStatus(let status): $0.statuses.append(status)
                    case .videoConfiguration(let configuration): $0.configurations.append(configuration)
                    case .videoAccessUnit(let frame): $0.frames.append(frame)
                    case .cursorPosition(let position): $0.cursor = position
                    case .pong(let payload): $0.pongs.append(payload)
                    case .videoDiscontinuity: break
                    }
                }
            }, onCompletion: { result in
                observed.update {
                    $0.completions += 1
                    if case .failure(let error) = result { $0.errors.append(error.localizedDescription) }
                }
            }))
            try await wait("authentication \(session)", observed) { $0.authentications.count == session + 1 }
            let authentication = observed.read { $0.authentications.last! }
            try require(authentication.hostIdentifier == hostID, "Host identity changed")
            try require(authentication.resumedSession == (session == 1), "Saved pairing did not resume")
            try require(authentication.supportsClipboardPaste && authentication.supportsStreamQuality
                        && authentication.supportsCursorPositionUpdates, "Released capabilities were lost")

            // Waiting for each status prevents normal coalescing from hiding a
            // missing decoder or an incompatible status value on either side.
            for state in HostProtocol.StreamState.allCases {
                host.publishStreamStatus(state: state, accessibilityGranted: state == .streaming)
                try await wait("status \(state)", observed) {
                    $0.statuses.last?.state.rawValue == state.rawValue
                        && $0.statuses.last?.accessibilityGranted == (state == .streaming)
                        && $0.statuses.last?.ownsInput == true
                }
            }
            host.publishStreamStatus(state: .streaming, accessibilityGranted: true)
            try await wait("capture resumed", observed) { $0.statuses.last?.state == .streaming }

            let expectedInputs: [HostProtocol.RemoteInputEvent] = [
                .pointer(.init(normalizedX: 12_345, normalizedY: 54_321, buttonMask: .left)),
                .pointer(.init(normalizedX: 12_345, normalizedY: 54_321, buttonMask: [])),
                .scroll(.init(direction: .down, steps: 3)),
                .key(.init(keysym: 0xFF52, isDown: true)),
                .key(.init(keysym: 0xFF52, isDown: false)),
                .text(.init(modifierMask: .shift, text: "Café 👋")),
                .clipboardPaste("Clipboard\nUnicode 👋"),
            ]
            client.sendPointerInput(x: 12_345, y: 54_321, buttons: .left)
            client.sendPointerInput(x: 12_345, y: 54_321, buttons: [])
            client.sendScrollInput(direction: .down, steps: 3)
            client.sendKeyInput(keysym: 0xFF52, isDown: true)
            client.sendKeyInput(keysym: 0xFF52, isDown: false)
            client.sendTextInput("Café 👋", modifiers: .shift)
            client.pasteClipboardText("Clipboard\nUnicode 👋")
            try await wait("all input payloads", observed) { $0.inputs.count == expectedInputs.count * (session + 1) }
            try require(observed.read { Array($0.inputs.suffix(expectedInputs.count)) == expectedInputs },
                        "Input payloads changed")
            client.setStreamQuality(.dataSaver)
            try await wait("quality selection", observed) { $0.qualities.last == .dataSaver }
            host.broadcastCursorPosition(.init(normalizedX: 123, normalizedY: UInt16(session)))
            try await wait("cursor position", observed) { $0.cursor == .init(x: 123, y: UInt16(session)) }

            let parameters = [Data([0x67, 0x42]), Data([0x68, 1])]
            let payload = Data(repeating: UInt8(session + 1), count: 256)
            host.broadcastCodecConfiguration(parameterSets: parameters, nalUnitHeaderLength: 4)
            host.broadcastVideoAccessUnit(payload, presentationTimeSeconds: 1,
                                          durationSeconds: 0.02, isKeyFrame: true)
            try await wait("video configuration and encrypted keyframe", observed) {
                $0.configurations.last == .init(nalUnitHeaderLength: 4, parameterSets: parameters)
                    && $0.frames.contains { $0.isKeyFrame && $0.data == payload }
            }
            client.sendPing(Data([UInt8(session)]))
            try await wait("pong", observed) { $0.pongs.contains(Data([UInt8(session)])) }
            client.disconnect()
            try await wait("disconnect", observed) { $0.completions == session + 1 && $0.clientCount == 0 }
        }

        let report: [String: Any] = observed.read {
            ["mode": CommandLine.arguments[2], "passed": true,
             "authentication": $0.authentications.map { $0.resumedSession ? "resume" : "pairing" },
             "status_values_received": Array(Set($0.statuses.map { Int($0.state.rawValue) })).sorted(),
             "input_packets_received": $0.inputs.count, "video_frames_received": $0.frames.count,
             "pong_count": $0.pongs.count, "errors": $0.errors]
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private static func wait(_ label: String, _ observations: Observations,
                             until predicate: @Sendable (Observation) -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let (satisfied, errors) = observations.read { (predicate($0), $0.errors) }
            try require(errors.isEmpty, "\(label): \(errors.joined(separator: "; "))")
            if satisfied { return }
            try require(ContinuousClock.now < deadline, "Timed out waiting for \(label)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct Failure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private struct Observation: Sendable {
    var port: UInt16?
    var clientCount = 0
    var authentications: [GlassyStreamAuthentication] = []
    var completions = 0
    var statuses: [GlassyStreamHostStatus] = []
    var inputs: [HostProtocol.RemoteInputEvent] = []
    var qualities: [HostProtocol.StreamQuality] = []
    var configurations: [GlassyStreamVideoConfiguration] = []
    var frames: [GlassyStreamVideoAccessUnit] = []
    var cursor: GlassyStreamCursorPosition?
    var pongs: [Data] = []
    var errors: [String] = []
}

private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Observation()
    func update(_ body: (inout Observation) -> Void) { lock.withLock { body(&value) } }
    func read<T>(_ body: (Observation) -> T) -> T { lock.withLock { body(value) } }
}

private final class MemoryCredentials: GlassyStreamResumeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: GlassyStreamResumeCredential] = [:]
    func credential(savedMachineID: UUID, hostIdentifier: Data) throws -> GlassyStreamResumeCredential? {
        lock.withLock { values[savedMachineID.uuidString + hostIdentifier.base64EncodedString()] }
    }
    func save(_ credential: GlassyStreamResumeCredential, savedMachineID: UUID, hostIdentifier: Data) throws {
        lock.withLock { values[savedMachineID.uuidString + hostIdentifier.base64EncodedString()] = credential }
    }
    func removeCredential(savedMachineID: UUID, hostIdentifier: Data) throws {
        _ = lock.withLock { values.removeValue(forKey: savedMachineID.uuidString + hostIdentifier.base64EncodedString()) }
    }
}
