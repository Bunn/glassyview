import CryptoKit
import Foundation

/// Moves files in both directions over one authenticated Glassy Stream session.
///
/// This file is compiled into Glassy Desk for iPhone and iPad and into the Mac
/// companion. Keep `dejaview/Services/FileTransfer/FileTransferEngine.swift`
/// and `GlassyHost/Sources/GlassyHost/FileTransfer/FileTransferEngine.swift`
/// byte-for-byte identical; a host test compares them.
///
/// All state and file I/O are confined to one serial queue, never the network
/// or main queue. Incoming messages must be delivered in the order the
/// connection received them. Senders keep at most
/// `FileTransferWire.windowChunkCount` chunks unacknowledged, so a large file
/// never builds a backlog ahead of input or video. Receivers write to a private
/// temporary file and only hand over a file whose length and SHA-256 match.
final class FileTransferEngine: @unchecked Sendable {
    typealias Status = FileTransferWire.Status

    enum Direction: Equatable, Sendable {
        case outgoing
        case incoming
    }

    enum State: Equatable, Sendable {
        /// Offered; waiting for the receiver to accept.
        case waiting
        case transferring
        /// All bytes sent; waiting for the receiver's verification result.
        case verifying
        /// `location` is the received file, or the name the receiver saved.
        case completed(location: String)
        case failed(Status, String)

        var isFinished: Bool {
            switch self {
            case .completed, .failed: true
            case .waiting, .transferring, .verifying: false
            }
        }
    }

    struct Snapshot: Equatable, Sendable, Identifiable {
        let id: Data
        let name: String
        let direction: Direction
        let totalBytes: UInt64
        var transferredBytes: UInt64
        var state: State
        /// The received file on this device, once completed.
        var fileURL: URL?
        /// Increases with every published change, across all transfers.
        var revision: UInt64
    }

    /// Decides what happens to files offered by the other side.
    struct ReceivePolicy: Sendable {
        /// Returns nil to accept, or the status and detail used to decline.
        var evaluate: @Sendable (_ name: String, _ size: UInt64, _ isSolicited: Bool) -> (Status, String)?
        /// Moves a verified temporary file to its final location.
        var finalize: @Sendable (_ temporaryURL: URL, _ name: String) throws -> URL
        var temporaryDirectory: URL
    }

    private struct Outgoing {
        let id: Data
        let name: String
        let size: UInt64
        let handle: FileHandle
        let onFinish: (@Sendable () -> Void)?
        var hasher = SHA256()
        var isAccepted = false
        var sentBytes: UInt64 = 0
        var acknowledgedBytes: UInt64 = 0
        var didSendCompletion = false
    }

    private struct Incoming {
        let id: Data
        let name: String
        let size: UInt64
        let temporaryURL: URL
        let handle: FileHandle
        var hasher = SHA256()
        var receivedBytes: UInt64 = 0
    }

    private let queue: DispatchQueue
    private let send: @Sendable (FileTransferWire.Message) -> Void
    private let policy: ReceivePolicy
    private let onChange: @Sendable (Snapshot) -> Void
    private let fileManager = FileManager.default

    private var outgoing: [Data: Outgoing] = [:]
    private var incoming: [Data: Incoming] = [:]
    private var snapshots: [Data: Snapshot] = [:]
    private var openRequests: Set<Data> = []
    private var requestCompletions: [Data: @Sendable (Status, String) -> Void] = [:]
    private var revision: UInt64 = 0

    init(label: String,
         send: @escaping @Sendable (FileTransferWire.Message) -> Void,
         policy: ReceivePolicy,
         onChange: @escaping @Sendable (Snapshot) -> Void) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.send = send
        self.policy = policy
        self.onChange = onChange
    }

    // MARK: - Public API

    /// Offers the file at `url`. `onFinish` runs on the engine queue after the
    /// transfer ends in any way, for example to release security-scoped access
    /// or delete a temporary copy. Returns the transfer identifier.
    @discardableResult
    func sendFile(at url: URL, name: String? = nil, onFinish: (@Sendable () -> Void)? = nil) -> Data {
        let id = FileTransferWire.makeIdentifier()
        queue.async { [self] in
            startOutgoing(id: id, url: url, proposedName: name ?? url.lastPathComponent, onFinish: onFinish)
        }
        return id
    }

    /// Sends a request to the other side. Offers that arrive before its result
    /// count as solicited. `completion` receives the request's result.
    @discardableResult
    func sendRequest(_ source: FileTransferWire.RequestSource,
                     completion: @escaping @Sendable (Status, String) -> Void) -> Data {
        let id = FileTransferWire.makeIdentifier()
        queue.async { [self] in
            openRequests.insert(id)
            requestCompletions[id] = completion
            send(.request(id: id, source: source))
        }
        return id
    }

    /// Answers a request from the other side. Queued after any offers made
    /// for it, so the requester sees every offer before this result.
    func respond(toRequest id: Data, status: Status, detail: String) {
        queue.async { [self] in
            send(.result(id: id, status: status, detail: detail))
        }
    }

    /// Delivers one message received from the connection.
    func receive(_ message: FileTransferWire.Message) {
        queue.async { [self] in handle(message) }
    }

    /// Cancels a transfer and tells the other side.
    func cancel(_ id: Data) {
        queue.async { [self] in
            guard outgoing[id] != nil || incoming[id] != nil else { return }
            send(.result(id: id, status: .cancelled, detail: ""))
            finish(id, state: .failed(.cancelled, ""))
        }
    }

    /// Ends every transfer locally, without sending anything, for example
    /// after the connection closes.
    func failAll(_ status: Status = .failed, detail: String) {
        queue.async { [self] in
            for id in Array(outgoing.keys) + Array(incoming.keys) {
                finish(id, state: .failed(status, detail))
            }
            let completions = requestCompletions.values
            requestCompletions.removeAll()
            openRequests.removeAll()
            completions.forEach { $0(status, detail) }
        }
    }

    /// Blocks until queued work has run. Intended for tests.
    func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - Outgoing

    private func startOutgoing(id: Data, url: URL, proposedName: String,
                               onFinish: (@Sendable () -> Void)?) {
        let name = FileTransferWire.sanitizedFileName(proposedName)
        let size: UInt64
        let handle: FileHandle
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                publishFailure(id: id, name: name, direction: .outgoing, status: .unsupportedItem,
                               detail: "Only files can be sent. Compress folders first.")
                onFinish?()
                return
            }
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard size <= FileTransferWire.maximumFileSize else {
                publishFailure(id: id, name: name, direction: .outgoing, status: .tooLarge,
                               detail: "Files larger than 64 GB can't be sent.")
                onFinish?()
                return
            }
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            publishFailure(id: id, name: name, direction: .outgoing, status: .failed,
                           detail: error.localizedDescription)
            onFinish?()
            return
        }

        outgoing[id] = Outgoing(id: id, name: name, size: size, handle: handle, onFinish: onFinish)
        publish(Snapshot(id: id, name: name, direction: .outgoing, totalBytes: size,
                         transferredBytes: 0, state: .waiting, fileURL: nil, revision: 0))
        send(.offer(id: id, size: size, name: name))
    }

    private func pump(_ id: Data) {
        guard var transfer = outgoing[id], transfer.isAccepted else { return }
        let window = UInt64(FileTransferWire.windowChunkCount * FileTransferWire.maximumChunkLength)
        do {
            while transfer.sentBytes < transfer.size,
                  transfer.sentBytes - transfer.acknowledgedBytes < window {
                let length = Int(min(UInt64(FileTransferWire.maximumChunkLength), transfer.size - transfer.sentBytes))
                guard let data = try transfer.handle.read(upToCount: length), !data.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                transfer.hasher.update(data: data)
                send(.chunk(id: id, offset: transfer.sentBytes, data: data))
                transfer.sentBytes += UInt64(data.count)
            }
        } catch {
            outgoing[id] = transfer
            send(.result(id: id, status: .failed, detail: "The file changed while it was being sent."))
            finish(id, state: .failed(.failed, "The file could not be read: \(error.localizedDescription)"))
            return
        }

        if transfer.sentBytes == transfer.size, !transfer.didSendCompletion {
            transfer.didSendCompletion = true
            send(.complete(id: id, sha256: Data(transfer.hasher.finalize())))
        }
        outgoing[id] = transfer
        update(id) {
            $0.transferredBytes = transfer.acknowledgedBytes
            $0.state = transfer.didSendCompletion && transfer.acknowledgedBytes == transfer.size ? .verifying : .transferring
        }
    }

    // MARK: - Incoming

    private func handle(_ message: FileTransferWire.Message) {
        switch message {
        case let .offer(id, size, name):
            receiveOffer(id: id, size: size, name: name)

        case let .chunk(id, offset, data):
            receiveChunk(id: id, offset: offset, data: data)

        case let .acknowledge(id, receivedBytes):
            guard var transfer = outgoing[id] else { return }
            guard receivedBytes <= transfer.sentBytes, receivedBytes >= transfer.acknowledgedBytes else {
                send(.result(id: id, status: .failed, detail: "Unexpected acknowledgement."))
                finish(id, state: .failed(.failed, "The receiver reported an unexpected position."))
                return
            }
            transfer.isAccepted = true
            transfer.acknowledgedBytes = receivedBytes
            outgoing[id] = transfer
            pump(id)

        case let .complete(id, sha256):
            receiveCompletion(id: id, sha256: sha256)

        case let .result(id, status, detail):
            if openRequests.remove(id) != nil {
                requestCompletions.removeValue(forKey: id)?(status, detail)
                return
            }
            if outgoing[id] != nil {
                finish(id, state: status == .completed ? .completed(location: detail) : .failed(status, detail))
            } else if incoming[id] != nil {
                finish(id, state: .failed(status == .completed ? .failed : status, detail))
            }

        case .request:
            // Requests are answered by the Mac companion before reaching the engine.
            break
        }
    }

    private func receiveOffer(id: Data, size: UInt64, name proposedName: String) {
        let name = FileTransferWire.sanitizedFileName(proposedName)
        guard outgoing[id] == nil, incoming[id] == nil else {
            send(.result(id: id, status: .declined, detail: "Duplicate transfer."))
            return
        }
        if let (status, detail) = policy.evaluate(name, size, !openRequests.isEmpty) {
            send(.result(id: id, status: status, detail: detail))
            publishFailure(id: id, name: name, direction: .incoming, status: status, detail: detail,
                           totalBytes: size)
            return
        }

        do {
            try fileManager.createDirectory(at: policy.temporaryDirectory, withIntermediateDirectories: true)
            let temporaryURL = policy.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
            guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            incoming[id] = Incoming(id: id, name: name, size: size, temporaryURL: temporaryURL, handle: handle)
        } catch {
            let detail = "The file could not be created: \(error.localizedDescription)"
            send(.result(id: id, status: .failed, detail: detail))
            publishFailure(id: id, name: name, direction: .incoming, status: .failed, detail: detail,
                           totalBytes: size)
            return
        }
        publish(Snapshot(id: id, name: name, direction: .incoming, totalBytes: size,
                         transferredBytes: 0, state: .transferring, fileURL: nil, revision: 0))
        send(.acknowledge(id: id, receivedBytes: 0))
    }

    private func receiveChunk(id: Data, offset: UInt64, data: Data) {
        guard var transfer = incoming[id] else { return }
        guard offset == transfer.receivedBytes,
              UInt64(data.count) <= transfer.size - transfer.receivedBytes else {
            send(.result(id: id, status: .failed, detail: "Unexpected file data."))
            finish(id, state: .failed(.failed, "The sender sent unexpected data."))
            return
        }
        do {
            try transfer.handle.write(contentsOf: data)
        } catch {
            let status: Status = (error as NSError).code == NSFileWriteOutOfSpaceError ? .insufficientSpace : .failed
            send(.result(id: id, status: status, detail: error.localizedDescription))
            finish(id, state: .failed(status, error.localizedDescription))
            return
        }
        transfer.hasher.update(data: data)
        transfer.receivedBytes += UInt64(data.count)
        incoming[id] = transfer
        send(.acknowledge(id: id, receivedBytes: transfer.receivedBytes))
        update(id) { $0.transferredBytes = transfer.receivedBytes }
    }

    private func receiveCompletion(id: Data, sha256: Data) {
        guard let transfer = incoming[id] else { return }
        guard transfer.receivedBytes == transfer.size,
              Data(transfer.hasher.finalize()) == sha256 else {
            let detail = "The received file did not match. Try sending it again."
            send(.result(id: id, status: .integrityFailure, detail: detail))
            finish(id, state: .failed(.integrityFailure, detail))
            return
        }
        do {
            try transfer.handle.close()
            let destination = try policy.finalize(transfer.temporaryURL, transfer.name)
            incoming[id] = nil
            send(.result(id: id, status: .completed, detail: destination.lastPathComponent))
            update(id) {
                $0.transferredBytes = transfer.size
                $0.state = .completed(location: destination.lastPathComponent)
                $0.fileURL = destination
            }
        } catch {
            let status: Status = (error as NSError).code == NSFileWriteOutOfSpaceError ? .insufficientSpace
                : ((error as NSError).code == NSFileWriteNoPermissionError ? .permissionRequired : .failed)
            send(.result(id: id, status: status, detail: error.localizedDescription))
            finish(id, state: .failed(status, error.localizedDescription))
        }
    }

    // MARK: - Bookkeeping

    private func finish(_ id: Data, state: State) {
        if let transfer = outgoing.removeValue(forKey: id) {
            try? transfer.handle.close()
            transfer.onFinish?()
            update(id) {
                if case .completed = state { $0.transferredBytes = transfer.size }
                $0.state = state
            }
        }
        if let transfer = incoming.removeValue(forKey: id) {
            try? transfer.handle.close()
            try? fileManager.removeItem(at: transfer.temporaryURL)
            update(id) { $0.state = state }
        }
    }

    private func publishFailure(id: Data, name: String, direction: Direction,
                                status: Status, detail: String, totalBytes: UInt64 = 0) {
        publish(Snapshot(id: id, name: name, direction: direction, totalBytes: totalBytes,
                         transferredBytes: 0, state: .failed(status, detail), fileURL: nil, revision: 0))
    }

    private func update(_ id: Data, _ change: (inout Snapshot) -> Void) {
        guard var snapshot = snapshots[id] else { return }
        let previous = snapshot
        change(&snapshot)
        guard snapshot != previous else { return }
        publish(snapshot)
    }

    private func publish(_ snapshot: Snapshot) {
        revision &+= 1
        var snapshot = snapshot
        snapshot.revision = revision
        if snapshot.state.isFinished {
            snapshots[snapshot.id] = nil
        } else {
            snapshots[snapshot.id] = snapshot
        }
        onChange(snapshot)
    }
}
