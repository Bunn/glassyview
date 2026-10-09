import CryptoKit
import Foundation
import Testing
@testable import GlassyDesk

@MainActor
struct FileTransferCenterTests {
    @Test
    func uploadReportsProgressAndTheNameSavedOnTheMac() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = fixture.root.appendingPathComponent("Slides.key")
        let contents = Data(repeating: 9, count: 80_000)
        try contents.write(to: source)

        fixture.center.sendFiles(at: [source])
        let offer = try await fixture.next { if case .offer = $0 { true } else { false } }
        guard case let .offer(id, size, name) = offer else { return }
        #expect(size == 80_000 && name == "Slides.key")
        try await fixture.waitUntil { fixture.center.items.first?.state == .waiting }

        fixture.center.engine.receive(.acknowledge(id: id, receivedBytes: 0))
        _ = try await fixture.next { if case .complete = $0 { true } else { false } }
        #expect(fixture.sentChunkBytes == 80_000)
        fixture.center.engine.receive(.acknowledge(id: id, receivedBytes: 80_000))
        fixture.center.engine.receive(.result(id: id, status: .completed, detail: "Slides 2.key"))

        try await fixture.waitUntil { fixture.center.items.first?.state.isFinished == true }
        let item = try #require(fixture.center.items.first)
        #expect(item.state == .completed(location: "Slides 2.key"))
        #expect(item.fractionCompleted == 1)
        #expect(!fixture.center.hasActiveTransfers)
        fixture.center.dismiss(item)
        #expect(fixture.center.items.isEmpty)
    }

    @Test
    func requestedFilesAreSavedForFilesAndUnrequestedOffersAreDeclined() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let unsolicited = FileTransferWire.makeIdentifier()
        fixture.center.engine.receive(.offer(id: unsolicited, size: 3, name: "surprise.txt"))
        let declined = try await fixture.next { if case .result(unsolicited, .declined, _) = $0 { true } else { false } }
        #expect(declined.transferID == unsolicited)

        fixture.center.getSelectedFilesFromMac()
        #expect(fixture.center.isRequestingFiles)
        let request = try await fixture.next { if case .request = $0 { true } else { false } }

        let id = FileTransferWire.makeIdentifier()
        let contents = Data("from the Mac".utf8)
        fixture.center.engine.receive(.offer(id: id, size: UInt64(contents.count), name: "../Report.pdf"))
        _ = try await fixture.next { if case .acknowledge(id, 0) = $0 { true } else { false } }
        fixture.center.engine.receive(.chunk(id: id, offset: 0, data: contents))
        fixture.center.engine.receive(.complete(id: id, sha256: Data(SHA256.hash(data: contents))))
        fixture.center.engine.receive(.result(id: request.transferID, status: .completed, detail: "Skipped 1 folder."))

        try await fixture.waitUntil {
            fixture.center.items.first { $0.id == id }?.state.isFinished == true && !fixture.center.isRequestingFiles
        }
        let item = try #require(fixture.center.items.first { $0.id == id })
        #expect(item.state == .completed(location: "Report.pdf"))
        let fileURL = try #require(item.fileURL)
        #expect(fileURL.deletingLastPathComponent().standardizedFileURL == fixture.locations.receivedDirectory.standardizedFileURL)
        #expect(try Data(contentsOf: fileURL) == contents)
        #expect(fixture.center.requestMessage == "Skipped 1 folder.")
    }

    @Test
    func emptySelectionExplainsWhatToDo() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.center.getSelectedFilesFromMac()
        let request = try await fixture.next { if case .request = $0 { true } else { false } }
        fixture.center.engine.receive(.result(id: request.transferID, status: .nothingSelected, detail: ""))
        try await fixture.waitUntil { !fixture.center.isRequestingFiles }
        #expect(fixture.center.requestMessage?.contains("Select one or more files") == true)
    }

    @Test
    func endingTheConnectionFailsActiveTransfers() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = fixture.root.appendingPathComponent("big.bin")
        try Data(count: 500_000).write(to: source)
        fixture.center.sendFiles(at: [source])
        _ = try await fixture.next { if case .offer = $0 { true } else { false } }
        try await fixture.waitUntil { fixture.center.hasActiveTransfers }

        fixture.center.connectionEnded()
        try await fixture.waitUntil { !fixture.center.hasActiveTransfers }
        #expect(fixture.center.items.first?.state == .failed(.failed, "The connection to your Mac ended."))
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let locations: FileTransferLocations
        let center: FileTransferCenter
        private let outbox = Outbox()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("FileTransferCenterTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            locations = FileTransferLocations(
                receivedDirectory: root.appendingPathComponent("From Mac", isDirectory: true),
                incomingTemporaryDirectory: root.appendingPathComponent("incoming", isDirectory: true),
                outgoingDirectory: root.appendingPathComponent("outgoing", isDirectory: true)
            )
            let outbox = outbox
            center = FileTransferCenter(locations: locations) { outbox.append($0) }
        }

        var sentChunkBytes: Int {
            outbox.messages.reduce(0) { total, message in
                if case let .chunk(_, _, data) = message { total + data.count } else { total }
            }
        }

        /// The first sent message matching `predicate` that has not been returned yet.
        func next(_ predicate: @escaping (FileTransferWire.Message) -> Bool) async throws -> FileTransferWire.Message {
            var found: FileTransferWire.Message?
            try await waitUntil {
                found = self.outbox.take(where: predicate)
                return found != nil
            }
            return found!
        }

        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                try #require(ContinuousClock.now < deadline, "Timed out waiting for a file transfer update")
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class Outbox: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [FileTransferWire.Message] = []
        private var consumed = 0

        var messages: [FileTransferWire.Message] { lock.withLock { all } }

        func append(_ message: FileTransferWire.Message) {
            lock.withLock { all.append(message) }
        }

        func take(where predicate: (FileTransferWire.Message) -> Bool) -> FileTransferWire.Message? {
            lock.withLock {
                guard let index = all.indices.dropFirst(consumed).first(where: { predicate(all[$0]) }) else { return nil }
                consumed = index + 1
                return all[index]
            }
        }
    }
}
