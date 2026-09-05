import ApplicationServices
import CoreGraphics
import Foundation

/// Core Graphics can cache the first denied result for the life of a process.
/// A short-lived instance of this same signed executable reads fresh TCC state
/// without opening a window, requesting access, or starting the host service.
enum HostPermissionStatusProbe {
    static let argument = "--glassy-permission-status"

    static func currentProcessSnapshot() -> HostPermissionSnapshot {
        HostPermissionSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    static func freshSnapshot() async throws -> HostPermissionSnapshot {
        guard let executableURL = Bundle.main.executableURL else {
            throw ProbeError.unavailable
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = [argument]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            try process.run()
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
            defer { timeout.cancel() }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 1_024 else {
                throw ProbeError.unavailable
            }
            return try JSONDecoder().decode(HostPermissionSnapshot.self, from: data)
        }.value
    }

    enum ProbeError: Error {
        case unavailable
    }
}
