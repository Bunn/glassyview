import AppKit
import Foundation
import OSLog

/// Saves files sent from iPhone and iPad to Downloads, and sends the files
/// selected in Finder when a device asks for them.
///
/// Each authenticated connection has its own engine. Only the connection that
/// owns input may start a transfer, matching keyboard and pointer control;
/// transfers already running continue if control moves. Everything ends when
/// the connection closes.
final class HostFileTransferService: @unchecked Sendable {
    static let allowsTransfersKey = "fileTransfer.allowsTransfers"
    static let defaultAllowsTransfers = true
    /// Leave room so a transfer never fills the startup disk.
    static let reservedFreeSpace: UInt64 = 512 * 1_024 * 1_024

    typealias Sender = @Sendable (FileTransferWire.Message, UUID) -> Void
    typealias FinderSelection = @Sendable () async -> Result<[URL], FinderSelectionError>

    enum FinderSelectionError: Error, Equatable, Sendable {
        case permissionDenied
        case unavailable(String)
    }

    private let lock = NSLock()
    private var engines: [UUID: FileTransferEngine] = [:]
    private let send: Sender
    private let defaults: UserDefaults
    private let downloadsDirectory: @Sendable () -> URL
    private let temporaryDirectory: URL
    private let availableCapacity: @Sendable (URL) -> UInt64?
    private let finderSelection: FinderSelection
    private let didReceiveFile: @Sendable (URL) -> Void

    init(send: @escaping Sender,
         defaults: UserDefaults = .standard,
         downloadsDirectory: @escaping @Sendable () -> URL = {
             FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                 ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
         },
         temporaryDirectory: URL = FileManager.default.temporaryDirectory
             .appendingPathComponent("GlassyDeskTransfers", isDirectory: true),
         availableCapacity: @escaping @Sendable (URL) -> UInt64? = HostFileTransferService.availableCapacity(at:),
         finderSelection: @escaping FinderSelection = { @MainActor in HostFinderSelection.selectedFileURLs() },
         didReceiveFile: @escaping @Sendable (URL) -> Void = HostFileTransferService.announceDownload(_:)) {
        self.send = send
        self.defaults = defaults
        self.downloadsDirectory = downloadsDirectory
        self.temporaryDirectory = temporaryDirectory
        self.availableCapacity = availableCapacity
        self.finderSelection = finderSelection
        self.didReceiveFile = didReceiveFile
    }

    var allowsTransfers: Bool {
        get { defaults.object(forKey: Self.allowsTransfersKey) as? Bool ?? Self.defaultAllowsTransfers }
        set { defaults.set(newValue, forKey: Self.allowsTransfersKey) }
    }

    /// Receives every authenticated file-transfer message in connection order.
    func handle(_ message: FileTransferWire.Message, from clientID: UUID, isInputOwner: Bool) {
        let engine = engine(for: clientID)
        switch message {
        case let .request(id, source):
            guard allowsTransfers else {
                engine.respond(toRequest: id, status: .disabled, detail: "File transfers are turned off on this Mac.")
                return
            }
            guard isInputOwner else {
                engine.respond(toRequest: id, status: .declined,
                               detail: "Only the device controlling this Mac can get files.")
                return
            }
            switch source {
            case .finderSelection:
                sendFinderSelection(answering: id, with: engine)
            }

        case let .offer(id, _, _) where !isInputOwner:
            send(.result(id: id, status: .declined, detail: "Only the device controlling this Mac can send files."),
                 clientID)

        default:
            engine.receive(message)
        }
    }

    /// Ends the connection's transfers and deletes partial files.
    func clientEnded(_ clientID: UUID) {
        let engine = lock.withLock { engines.removeValue(forKey: clientID) }
        engine?.failAll(detail: "The connection ended.")
    }

    // MARK: - Private

    private func engine(for clientID: UUID) -> FileTransferEngine {
        lock.withLock {
            if let engine = engines[clientID] { return engine }
            let send = send
            let engine = FileTransferEngine(
                label: "dev.bunn.glassydesk.host.file-transfer",
                send: { message in send(message, clientID) },
                policy: receivePolicy(),
                onChange: { snapshot in
                    guard snapshot.state.isFinished else { return }
                    HostLog.network.info("File transfer finished direction=\(snapshot.direction == .incoming ? "received" : "sent", privacy: .public) bytes=\(snapshot.totalBytes) state=\(String(describing: snapshot.state), privacy: .public)")
                }
            )
            engines[clientID] = engine
            return engine
        }
    }

    private func receivePolicy() -> FileTransferEngine.ReceivePolicy {
        let downloadsDirectory = downloadsDirectory
        let availableCapacity = availableCapacity
        let didReceiveFile = didReceiveFile
        return FileTransferEngine.ReceivePolicy(
            evaluate: { [self] _, size, _ in
                guard allowsTransfers else {
                    return (.disabled, "File transfers are turned off on this Mac.")
                }
                if let available = availableCapacity(downloadsDirectory()),
                   size > available || available - size < Self.reservedFreeSpace {
                    return (.insufficientSpace, "This Mac doesn't have enough free space for this file.")
                }
                return nil
            },
            finalize: { temporaryURL, name in
                let directory = downloadsDirectory()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = FileTransferWire.uniqueDestination(for: name, in: directory)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                didReceiveFile(destination)
                return destination
            },
            temporaryDirectory: temporaryDirectory
        )
    }

    private func sendFinderSelection(answering requestID: Data, with engine: FileTransferEngine) {
        let finderSelection = finderSelection
        Task {
            switch await finderSelection() {
            case .failure(.permissionDenied):
                engine.respond(toRequest: requestID, status: .permissionRequired,
                               detail: "On your Mac, allow Glassy Desk to control Finder in System Settings > Privacy & Security > Automation.")
            case let .failure(.unavailable(message)):
                engine.respond(toRequest: requestID, status: .failed, detail: message)
            case let .success(urls):
                let files = urls.filter { url in
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                let skipped = urls.count - files.count
                guard !files.isEmpty else {
                    engine.respond(toRequest: requestID,
                                   status: urls.isEmpty ? .nothingSelected : .unsupportedItem,
                                   detail: urls.isEmpty
                                       ? "Select one or more files in Finder on your Mac, then try again."
                                       : "Folders can't be sent. Compress them in Finder first.")
                    return
                }
                let sent = files.prefix(FileTransferWire.maximumFilesPerRequest)
                for url in sent {
                    engine.sendFile(at: url)
                }
                var notes: [String] = []
                if skipped > 0 { notes.append("Skipped \(skipped) folder\(skipped == 1 ? "" : "s").") }
                if files.count > sent.count {
                    notes.append("Sent the first \(sent.count) of \(files.count) files.")
                }
                engine.respond(toRequest: requestID, status: .completed, detail: notes.joined(separator: " "))
            }
        }
    }

    static func availableCapacity(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 >= 0 ? UInt64($0) : nil }
    }

    /// Bounces the Downloads stack in the Dock, as Safari and AirDrop do.
    static func announceDownload(_ url: URL) {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"),
            object: url.path
        )
    }
}

/// Reads the selection in the frontmost Finder window through Apple Events.
/// The first request asks the person at the Mac, or the remote viewer seeing
/// its screen, to let Glassy Desk control Finder.
enum HostFinderSelection {
    private static let script = """
    tell application "Finder"
        set selectedItems to selection as alias list
        set output to ""
        repeat with selectedItem in selectedItems
            set output to output & (POSIX path of selectedItem) & linefeed
        end repeat
        return output
    end tell
    """

    @MainActor
    static func selectedFileURLs() -> Result<[URL], HostFileTransferService.FinderSelectionError> {
        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(.unavailable("Finder could not be asked for its selection."))
        }
        var errorInfo: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            // errAEEventNotPermitted / errAEEventWouldRequireUserConsent
            if number == -1_743 || number == -1_744 {
                return .failure(.permissionDenied)
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Finder returned error \(number)."
            return .failure(.unavailable(message))
        }
        let paths = (descriptor.stringValue ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return .success(paths.map { URL(fileURLWithPath: $0) })
    }
}
