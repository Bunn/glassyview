import CryptoKit
import Foundation
import Testing
@testable import GlassyHost

// MARK: - Wire format

@Test("Every file transfer message round-trips and rejects malformed payloads")
func fileTransferWireRoundTrip() throws {
    let id = FileTransferWire.makeIdentifier()
    let messages: [FileTransferWire.Message] = [
        .offer(id: id, size: 12_345, name: "Report 📄.pdf"),
        .chunk(id: id, offset: 65_536, data: Data(repeating: 7, count: FileTransferWire.maximumChunkLength)),
        .acknowledge(id: id, receivedBytes: 98_304),
        .complete(id: id, sha256: Data(SHA256.hash(data: Data("x".utf8)))),
        .result(id: id, status: .insufficientSpace, detail: "Not enough space."),
        .result(id: id, status: .completed, detail: ""),
        .request(id: id, source: .finderSelection)
    ]
    for message in messages {
        let payload = try FileTransferWire.encode(message)
        #expect(try FileTransferWire.decode(kind: message.kind.rawValue, payload: payload) == message)
        #expect(HostProtocol.MessageKind(message.kind).isFileTransfer)
    }

    // Short identifier, empty chunk, oversized chunk, empty name, trailing bytes, unknown status.
    #expect(throws: FileTransferWire.WireError.self) { try FileTransferWire.decode(kind: 0x32, payload: Data(count: 10)) }
    #expect(throws: FileTransferWire.WireError.self) { try FileTransferWire.decode(kind: 0x31, payload: id + Data(count: 8)) }
    #expect(throws: FileTransferWire.WireError.self) {
        try FileTransferWire.decode(kind: 0x31, payload: id + Data(count: 8 + FileTransferWire.maximumChunkLength + 1))
    }
    #expect(throws: FileTransferWire.WireError.self) { try FileTransferWire.decode(kind: 0x30, payload: id + Data(count: 8) + Data([0, 0])) }
    #expect(throws: FileTransferWire.WireError.self) { try FileTransferWire.decode(kind: 0x32, payload: id + Data(count: 9)) }
    #expect(throws: FileTransferWire.WireError.self) { try FileTransferWire.decode(kind: 0x34, payload: id + Data([99, 0, 0])) }
    #expect(throws: FileTransferWire.WireError.self) {
        try FileTransferWire.encode(.offer(id: id, size: FileTransferWire.maximumFileSize + 1, name: "big"))
    }
    #expect(throws: FileTransferWire.WireError.self) { try FileTransferWire.encode(.chunk(id: id, offset: 0, data: Data())) }
}

@Test("Host advertises file transfer and maps exactly its six message kinds")
func fileTransferCapabilityAndKinds() {
    #expect(HostProtocol.advertisedCapabilities.contains(.fileTransfer))
    #expect(HostProtocol.Capabilities.fileTransfer.rawValue == 1 << 8)
    let kinds = (0...255).compactMap { HostProtocol.MessageKind(rawValue: UInt8($0)) }.filter(\.isFileTransfer)
    #expect(kinds.map(\.rawValue) == FileTransferWire.Kind.allCases.map(\.rawValue))
    #expect(!HostProtocol.MessageKind.clipboardPaste.isFileTransfer)
}

@Test("Received names are single safe path components with their extension kept")
func fileTransferNameSanitization() throws {
    #expect(FileTransferWire.sanitizedFileName("../../etc/passwd") == "passwd")
    #expect(FileTransferWire.sanitizedFileName("C:\\Users\\me\\notes.txt") == "notes.txt")
    #expect(FileTransferWire.sanitizedFileName(".hidden") == "hidden")
    #expect(FileTransferWire.sanitizedFileName("  ") == "File")
    #expect(FileTransferWire.sanitizedFileName("a\u{0}b\u{202E}c:d.png") == "a-b-c-d.png")
    let long = String(repeating: "é", count: 300) + ".jpeg"
    let sanitized = FileTransferWire.sanitizedFileName(long)
    #expect(sanitized.utf8.count <= FileTransferWire.maximumNameByteCount)
    #expect(sanitized.hasSuffix(".jpeg"))

    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(FileTransferWire.uniqueDestination(for: "Photo.heic", in: directory).lastPathComponent == "Photo.heic")
    FileManager.default.createFile(atPath: directory.appendingPathComponent("Photo.heic").path, contents: Data())
    FileManager.default.createFile(atPath: directory.appendingPathComponent("Photo 2.heic").path, contents: Data())
    #expect(FileTransferWire.uniqueDestination(for: "Photo.heic", in: directory).lastPathComponent == "Photo 3.heic")
    FileManager.default.createFile(atPath: directory.appendingPathComponent("README").path, contents: Data())
    #expect(FileTransferWire.uniqueDestination(for: "README", in: directory).lastPathComponent == "README 2")
}

@Test("The iOS and Mac copies of the shared file-transfer sources are identical")
func sharedFileTransferSourcesMatch() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for name in ["FileTransferWire.swift", "FileTransferEngine.swift"] {
        let host = try Data(contentsOf: repository.appendingPathComponent("GlassyHost/Sources/GlassyHost/FileTransfer/\(name)"))
        let app = try Data(contentsOf: repository.appendingPathComponent("dejaview/Services/FileTransfer/\(name)"))
        #expect(host == app, "\(name) differs between Glassy Desk and the Mac companion")
    }
}

// MARK: - Engine

@Test("A multi-chunk file arrives intact, flow-controlled, and moves to its destination")
func fileTransferEndToEnd() async throws {
    let link = try EngineLink()
    defer { link.cleanUp() }
    let contents = Data((0..<(FileTransferWire.maximumChunkLength * 9 + 123)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let source = try link.writeSource(named: "Movie.mov", contents: contents)
    let finished = Flag()

    let id = link.sender.sendFile(at: source, onFinish: { finished.set() })
    try await link.waitUntil { link.receiverState(id)?.isFinished == true && link.senderState(id)?.isFinished == true }

    #expect(link.receiverState(id) == .completed(location: "Movie.mov"))
    #expect(link.senderState(id) == .completed(location: "Movie.mov"))
    #expect(try Data(contentsOf: link.destination.appendingPathComponent("Movie.mov")) == contents)
    #expect(finished.isSet)
    #expect(link.maximumUnacknowledgedBytes <= FileTransferWire.windowChunkCount * FileTransferWire.maximumChunkLength)
    #expect(try FileManager.default.contentsOfDirectory(atPath: link.receiverTemporary.path).isEmpty)
}

@Test("An empty file still completes with verification")
func fileTransferEmptyFile() async throws {
    let link = try EngineLink()
    defer { link.cleanUp() }
    let source = try link.writeSource(named: "empty.txt", contents: Data())
    let id = link.sender.sendFile(at: source)
    try await link.waitUntil { link.senderState(id)?.isFinished == true }
    #expect(link.senderState(id) == .completed(location: "empty.txt"))
    #expect(try Data(contentsOf: link.destination.appendingPathComponent("empty.txt")).isEmpty)
}

@Test("Corrupted data is rejected and no partial file is kept")
func fileTransferIntegrityFailure() async throws {
    let link = try EngineLink(corruptChunks: true)
    defer { link.cleanUp() }
    let source = try link.writeSource(named: "doc.pdf", contents: Data(repeating: 1, count: 70_000))
    let id = link.sender.sendFile(at: source)
    try await link.waitUntil { link.senderState(id)?.isFinished == true && link.receiverState(id)?.isFinished == true }
    #expect(link.senderState(id).map { if case .failed(.integrityFailure, _) = $0 { true } else { false } } == true)
    #expect(!FileManager.default.fileExists(atPath: link.destination.appendingPathComponent("doc.pdf").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: link.receiverTemporary.path).isEmpty)
}

@Test("A declined offer, a cancel, and a dropped connection all end cleanly")
func fileTransferDeclineCancelAndDisconnect() async throws {
    let declining = try EngineLink(decline: (.disabled, "Off"))
    defer { declining.cleanUp() }
    let declined = declining.sender.sendFile(at: try declining.writeSource(named: "a.txt", contents: Data("a".utf8)))
    try await declining.waitUntil { declining.senderState(declined)?.isFinished == true }
    #expect(declining.senderState(declined) == .failed(.disabled, "Off"))

    // Holding acknowledgements stalls the sender at its window mid-transfer.
    let cancelling = try EngineLink(holdsAcknowledgementsAfter: 2)
    defer { cancelling.cleanUp() }
    let cancelled = cancelling.sender.sendFile(at: try cancelling.writeSource(named: "large.bin", contents: Data(count: 1_000_000)))
    try await cancelling.waitUntil { (cancelling.receiverSnapshot(cancelled)?.transferredBytes ?? 0) > 0 }
    cancelling.sender.cancel(cancelled)
    try await cancelling.waitUntil { cancelling.receiverState(cancelled)?.isFinished == true }
    #expect(cancelling.receiverState(cancelled) == .failed(.cancelled, ""))
    #expect(cancelling.senderState(cancelled) == .failed(.cancelled, ""))
    #expect(try FileManager.default.contentsOfDirectory(atPath: cancelling.receiverTemporary.path).isEmpty)

    let dropping = try EngineLink(holdsAcknowledgementsAfter: 2)
    defer { dropping.cleanUp() }
    let interrupted = dropping.sender.sendFile(at: try dropping.writeSource(named: "large.bin", contents: Data(count: 1_000_000)))
    try await dropping.waitUntil { (dropping.receiverSnapshot(interrupted)?.transferredBytes ?? 0) > 0 }
    dropping.sender.failAll(detail: "The connection ended.")
    dropping.receiver.failAll(detail: "The connection ended.")
    try await dropping.waitUntil {
        dropping.receiverState(interrupted)?.isFinished == true && dropping.senderState(interrupted)?.isFinished == true
    }
    #expect(dropping.senderState(interrupted) == .failed(.failed, "The connection ended."))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dropping.receiverTemporary.path).isEmpty)
}

@Test("Folders are not offered")
func fileTransferRejectsFolders() async throws {
    let link = try EngineLink()
    defer { link.cleanUp() }
    let folder = link.sourceDirectory.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let finished = Flag()
    let id = link.sender.sendFile(at: folder, onFinish: { finished.set() })
    try await link.waitUntil { link.senderState(id)?.isFinished == true }
    #expect(link.senderState(id).map { if case .failed(.unsupportedItem, _) = $0 { true } else { false } } == true)
    #expect(finished.isSet)
    #expect(link.sentKinds.isEmpty)
}

// MARK: - Host service

@Test("Uploads go to Downloads only from the controlling device and only when allowed")
func hostFileTransferServiceGating() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
    let defaults = try #require(UserDefaults(suiteName: "HostFileTransferTests.\(UUID().uuidString)"))
    let outbox = Outbox()
    let announced = Outbox()
    let service = HostFileTransferService(
        send: { message, _ in outbox.append(message) },
        defaults: defaults,
        downloadsDirectory: { downloads },
        temporaryDirectory: directory.appendingPathComponent("tmp", isDirectory: true),
        availableCapacity: { _ in 10 * 1_024 * 1_024 * 1_024 },
        finderSelection: { .success([]) },
        didReceiveFile: { announced.append(.result(id: Data(count: 16), status: .completed, detail: $0.lastPathComponent)) }
    )
    let client = UUID()
    let contents = Data("hello from iPad".utf8)

    // A view-only device is declined before any file is created.
    let viewOnly = FileTransferWire.makeIdentifier()
    service.handle(.offer(id: viewOnly, size: UInt64(contents.count), name: "a.txt"), from: client, isInputOwner: false)
    #expect(outbox.messages.last == .result(id: viewOnly, status: .declined,
                                           detail: "Only the device controlling this Mac can send files."))

    // The controlling device's upload is saved under a unique name.
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: downloads.appendingPathComponent("a.txt").path, contents: Data())
    let upload = FileTransferWire.makeIdentifier()
    service.handle(.offer(id: upload, size: UInt64(contents.count), name: "a.txt"), from: client, isInputOwner: true)
    try await waitForCondition { outbox.messages.contains(.acknowledge(id: upload, receivedBytes: 0)) }
    service.handle(.chunk(id: upload, offset: 0, data: contents), from: client, isInputOwner: false)
    service.handle(.complete(id: upload, sha256: Data(SHA256.hash(data: contents))), from: client, isInputOwner: false)
    try await waitForCondition { outbox.messages.contains(.result(id: upload, status: .completed, detail: "a 2.txt")) }
    #expect(try Data(contentsOf: downloads.appendingPathComponent("a 2.txt")) == contents)
    #expect(announced.messages.count == 1)

    // Turning transfers off declines new offers and requests.
    service.allowsTransfers = false
    let disabled = FileTransferWire.makeIdentifier()
    service.handle(.offer(id: disabled, size: 1, name: "b.txt"), from: client, isInputOwner: true)
    let request = FileTransferWire.makeIdentifier()
    service.handle(.request(id: request, source: .finderSelection), from: client, isInputOwner: true)
    try await waitForCondition { outbox.messages.contains { if case .result(request, .disabled, _) = $0 { true } else { false } } }
    #expect(outbox.messages.contains { if case .result(disabled, .disabled, _) = $0 { true } else { false } })
}

@Test("Finder requests offer files, skip folders, and report empty selections")
func hostFileTransferFinderRequests() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Selected.txt")
    try Data("selected".utf8).write(to: file)
    let folder = directory.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let selection = SelectionBox([file, folder])
    let outbox = Outbox()
    let service = HostFileTransferService(
        send: { message, _ in outbox.append(message) },
        defaults: try #require(UserDefaults(suiteName: "HostFileTransferTests.\(UUID().uuidString)")),
        downloadsDirectory: { directory },
        temporaryDirectory: directory.appendingPathComponent("tmp", isDirectory: true),
        finderSelection: { selection.result },
        didReceiveFile: { _ in }
    )
    let client = UUID()

    let viewOnlyRequest = FileTransferWire.makeIdentifier()
    service.handle(.request(id: viewOnlyRequest, source: .finderSelection), from: client, isInputOwner: false)
    try await waitForCondition { outbox.messages.contains { if case .result(viewOnlyRequest, .declined, _) = $0 { true } else { false } } }

    let request = FileTransferWire.makeIdentifier()
    service.handle(.request(id: request, source: .finderSelection), from: client, isInputOwner: true)
    try await waitForCondition { outbox.messages.contains { if case .result(request, _, _) = $0 { true } else { false } } }
    let offerIndex = try #require(outbox.messages.firstIndex { if case .offer(_, 8, "Selected.txt") = $0 { true } else { false } })
    let resultIndex = try #require(outbox.messages.firstIndex { if case .result(request, .completed, "Skipped 1 folder.") = $0 { true } else { false } })
    #expect(offerIndex < resultIndex, "Offers precede the request result")

    selection.result = .success([])
    let empty = FileTransferWire.makeIdentifier()
    service.handle(.request(id: empty, source: .finderSelection), from: client, isInputOwner: true)
    try await waitForCondition { outbox.messages.contains { if case .result(empty, .nothingSelected, _) = $0 { true } else { false } } }

    selection.result = .failure(.permissionDenied)
    let denied = FileTransferWire.makeIdentifier()
    service.handle(.request(id: denied, source: .finderSelection), from: client, isInputOwner: true)
    try await waitForCondition { outbox.messages.contains { if case .result(denied, .permissionRequired, _) = $0 { true } else { false } } }

    service.clientEnded(client)
}

// MARK: - Fixtures

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("HostFileTransferTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func waitForCondition(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for a file transfer condition")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FileTransferWire.Message] = []
    var messages: [FileTransferWire.Message] { lock.withLock { storage } }
    func append(_ message: FileTransferWire.Message) { lock.withLock { storage.append(message) } }
}

private final class SelectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<[URL], HostFileTransferService.FinderSelectionError>
    init(_ urls: [URL]) { value = .success(urls) }
    var result: Result<[URL], HostFileTransferService.FinderSelectionError> {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Two engines wired back to back through encode/decode, like a connection.
private final class EngineLink: @unchecked Sendable {
    let root: URL
    let sourceDirectory: URL
    let destination: URL
    let receiverTemporary: URL
    private(set) var sender: FileTransferEngine!
    private(set) var receiver: FileTransferEngine!
    private let lock = NSLock()
    private var senderSnapshots: [Data: FileTransferEngine.Snapshot] = [:]
    private var receiverSnapshots: [Data: FileTransferEngine.Snapshot] = [:]
    private var sentBytes: [Data: Int] = [:]
    private var acknowledgedBytes: [Data: Int] = [:]
    private var maximumUnacknowledged = 0
    private var kinds: [FileTransferWire.Kind] = []
    private var acknowledgementCount = 0
    private let holdsAcknowledgementsAfter: Int?

    init(corruptChunks: Bool = false, decline: (FileTransferWire.Status, String)? = nil,
         holdsAcknowledgementsAfter: Int? = nil) throws {
        root = try temporaryDirectory()
        sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        receiverTemporary = root.appendingPathComponent("tmp", isDirectory: true)
        self.holdsAcknowledgementsAfter = holdsAcknowledgementsAfter
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiverTemporary, withIntermediateDirectories: true)

        let destination = destination
        sender = FileTransferEngine(
            label: "test.sender",
            send: { [unowned self] message in
                var message = message
                if corruptChunks, case let .chunk(id, offset, data) = message {
                    var data = data
                    data[data.startIndex] ^= 0xFF
                    message = .chunk(id: id, offset: offset, data: data)
                }
                lock.withLock {
                    kinds.append(message.kind)
                    if case let .chunk(id, _, data) = message {
                        sentBytes[id, default: 0] += data.count
                        maximumUnacknowledged = max(maximumUnacknowledged,
                                                    sentBytes[id, default: 0] - acknowledgedBytes[id, default: 0])
                    }
                }
                deliver(message, to: \.receiver)
            },
            policy: .init(evaluate: { _, _, _ in nil }, finalize: { url, _ in url }, temporaryDirectory: receiverTemporary),
            onChange: { [unowned self] snapshot in lock.withLock { senderSnapshots[snapshot.id] = snapshot } }
        )
        receiver = FileTransferEngine(
            label: "test.receiver",
            send: { [unowned self] message in
                if case let .acknowledge(id, received) = message {
                    let isHeld = lock.withLock {
                        acknowledgedBytes[id] = Int(received)
                        acknowledgementCount += 1
                        return holdsAcknowledgementsAfter.map { acknowledgementCount > $0 } ?? false
                    }
                    if isHeld { return }
                }
                deliver(message, to: \.sender)
            },
            policy: .init(
                evaluate: { _, _, _ in decline },
                finalize: { temporaryURL, name in
                    let url = FileTransferWire.uniqueDestination(for: name, in: destination)
                    try FileManager.default.moveItem(at: temporaryURL, to: url)
                    return url
                },
                temporaryDirectory: receiverTemporary
            ),
            onChange: { [unowned self] snapshot in lock.withLock { receiverSnapshots[snapshot.id] = snapshot } }
        )
    }

    private func deliver(_ message: FileTransferWire.Message, to engine: KeyPath<EngineLink, FileTransferEngine?>) {
        // Round-trip through the wire format, as the connection would.
        let decoded = try! FileTransferWire.decode(kind: message.kind.rawValue, payload: FileTransferWire.encode(message))
        self[keyPath: engine]!.receive(decoded)
    }

    var maximumUnacknowledgedBytes: Int { lock.withLock { maximumUnacknowledged } }
    var sentKinds: [FileTransferWire.Kind] { lock.withLock { kinds } }
    func senderState(_ id: Data) -> FileTransferEngine.State? { lock.withLock { senderSnapshots[id]?.state } }
    func receiverState(_ id: Data) -> FileTransferEngine.State? { lock.withLock { receiverSnapshots[id]?.state } }
    func receiverSnapshot(_ id: Data) -> FileTransferEngine.Snapshot? { lock.withLock { receiverSnapshots[id] } }

    func writeSource(named name: String, contents: Data) throws -> URL {
        let url = sourceDirectory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        try await waitForCondition(condition)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
