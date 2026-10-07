import Foundation
import Observation
import OSLog

/// Session-scoped state for sending files to the Mac and getting the files
/// selected in its Finder. Transfers last as long as the connection; when it
/// ends, unfinished transfers fail and partial files are deleted.
@MainActor
@Observable
final class FileTransferCenter {
    struct Item: Identifiable, Equatable {
        let id: Data
        let name: String
        let direction: FileTransferEngine.Direction
        let totalBytes: UInt64
        var transferredBytes: UInt64
        var state: FileTransferEngine.State
        var fileURL: URL?
        fileprivate var revision: UInt64

        var fractionCompleted: Double {
            guard totalBytes > 0 else { return state.isFinished ? 1 : 0 }
            return min(1, Double(transferredBytes) / Double(totalBytes))
        }
    }

    /// Newest first. Finished items stay until dismissed.
    private(set) var items: [Item] = []
    private(set) var isRequestingFiles = false
    /// Explains why a request for the Mac's Finder selection sent nothing.
    var requestMessage: String?

    @ObservationIgnored let engine: FileTransferEngine
    @ObservationIgnored private let locations: FileTransferLocations

    init(locations: FileTransferLocations = .live,
         send: @escaping @Sendable (FileTransferWire.Message) -> Void) {
        self.locations = locations
        let changes = SnapshotRelay()
        engine = FileTransferEngine(
            label: "dev.bunn.glassydesk.file-transfer",
            send: send,
            policy: locations.receivePolicy,
            onChange: { snapshot in changes.publish(snapshot) }
        )
        changes.center = self
    }

    var hasActiveTransfers: Bool {
        items.contains { !$0.state.isFinished }
    }

    // MARK: - Sending

    /// Sends files chosen in Files. Security-scoped access lasts until each
    /// transfer ends.
    func sendFiles(at urls: [URL]) {
        for url in urls {
            let isScoped = url.startAccessingSecurityScopedResource()
            engine.sendFile(at: url) {
                if isScoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    /// Sends a private copy that this app owns, then deletes it.
    func sendTemporaryCopy(at url: URL, name: String) {
        engine.sendFile(at: url, name: name) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    /// Copies a file that is only valid during a callback (drag and drop,
    /// Photos) into a private folder and sends it.
    nonisolated static func makeTemporaryCopy(of url: URL, name: String) throws -> URL {
        let folder = FileTransferLocations.live.outgoingDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(FileTransferWire.sanitizedFileName(name), isDirectory: false)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    // MARK: - Receiving

    /// Asks the Mac for the files selected in its frontmost Finder window.
    func getSelectedFilesFromMac() {
        guard !isRequestingFiles else { return }
        isRequestingFiles = true
        requestMessage = nil
        engine.sendRequest(.finderSelection) { [weak self] status, detail in
            Task { @MainActor in
                self?.requestFinished(status: status, detail: detail)
            }
        }
    }

    // MARK: - Management

    func cancel(_ item: Item) {
        engine.cancel(item.id)
    }

    func dismiss(_ item: Item) {
        guard item.state.isFinished else { return }
        items.removeAll { $0.id == item.id }
    }

    func dismissFinished() {
        items.removeAll { $0.state.isFinished }
    }

    /// Fails unfinished transfers after the connection closes.
    func connectionEnded() {
        isRequestingFiles = false
        guard hasActiveTransfers else { return }
        engine.failAll(detail: String(localized: "The connection to your Mac ended."))
    }

    fileprivate func apply(_ snapshot: FileTransferEngine.Snapshot) {
        if let index = items.firstIndex(where: { $0.id == snapshot.id }) {
            // Engine snapshots can reach the main actor out of order.
            guard snapshot.revision > items[index].revision else { return }
            items[index].transferredBytes = snapshot.transferredBytes
            items[index].state = snapshot.state
            items[index].fileURL = snapshot.fileURL ?? items[index].fileURL
            items[index].revision = snapshot.revision
        } else {
            items.insert(Item(id: snapshot.id, name: snapshot.name, direction: snapshot.direction,
                              totalBytes: snapshot.totalBytes, transferredBytes: snapshot.transferredBytes,
                              state: snapshot.state, fileURL: snapshot.fileURL, revision: snapshot.revision),
                         at: 0)
        }
    }

    private func requestFinished(status: FileTransferWire.Status, detail: String) {
        isRequestingFiles = false
        switch status {
        case .completed:
            requestMessage = detail.isEmpty ? nil : detail
        case .nothingSelected:
            requestMessage = String(localized: "Nothing is selected in Finder on your Mac. Select one or more files, then try again.")
        default:
            requestMessage = detail.isEmpty
                ? String(localized: "Your Mac couldn't send the selected files.")
                : detail
        }
        if let requestMessage {
            AppLog.session.info("Finder selection request finished: \(requestMessage, privacy: .public)")
        }
    }
}

/// Hands engine snapshots to the main actor without retaining the center.
private final class SnapshotRelay: @unchecked Sendable {
    weak var center: FileTransferCenter?

    func publish(_ snapshot: FileTransferEngine.Snapshot) {
        Task { @MainActor [weak self] in
            self?.center?.apply(snapshot)
        }
    }
}

/// Where transfers live on this device.
struct FileTransferLocations: Sendable {
    /// Received files, visible in Files › On My iPhone › Glassy Desk.
    let receivedDirectory: URL
    /// Partial downloads; removed if a transfer does not complete.
    let incomingTemporaryDirectory: URL
    /// Private copies of dropped files and photos while they are sent.
    let outgoingDirectory: URL

    static let live: FileTransferLocations = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let temporary = FileManager.default.temporaryDirectory
        return FileTransferLocations(
            receivedDirectory: documents.appendingPathComponent("From Mac", isDirectory: true),
            incomingTemporaryDirectory: temporary.appendingPathComponent("GlassyDeskIncoming", isDirectory: true),
            outgoingDirectory: temporary.appendingPathComponent("GlassyDeskOutgoing", isDirectory: true)
        )
    }()

    /// Space to leave free on the device after a download.
    static let reservedFreeSpace: UInt64 = 256 * 1_024 * 1_024

    var receivePolicy: FileTransferEngine.ReceivePolicy {
        let receivedDirectory = receivedDirectory
        return FileTransferEngine.ReceivePolicy(
            evaluate: { _, size, isSolicited in
                // The Mac only offers files this device asked for.
                guard isSolicited else {
                    return (.declined, "This iPhone or iPad didn't ask for files.")
                }
                let values = try? receivedDirectory.deletingLastPathComponent()
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                if let available = values?.volumeAvailableCapacityForImportantUsage, available >= 0,
                   size > UInt64(available) || UInt64(available) - size < Self.reservedFreeSpace {
                    return (.insufficientSpace, "The iPhone or iPad doesn't have enough free space.")
                }
                return nil
            },
            finalize: { temporaryURL, name in
                try FileManager.default.createDirectory(at: receivedDirectory, withIntermediateDirectories: true)
                let destination = FileTransferWire.uniqueDestination(for: name, in: receivedDirectory)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                return destination
            },
            temporaryDirectory: incomingTemporaryDirectory
        )
    }
}
