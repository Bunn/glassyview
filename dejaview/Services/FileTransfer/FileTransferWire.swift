import Foundation

/// Glassy Stream file transfer (protocol v1, capability bit 8).
///
/// This file is compiled into Glassy Desk for iPhone and iPad and into the Mac
/// companion. Keep `dejaview/Services/FileTransfer/FileTransferWire.swift` and
/// `GlassyHost/Sources/GlassyHost/FileTransfer/FileTransferWire.swift`
/// byte-for-byte identical; a host test compares them.
///
/// Every message travels inside the existing encrypted, sequenced session.
/// Integer fields are big-endian. A transfer is identified by 16 random bytes
/// chosen by its sender.
enum FileTransferWire {
    static let identifierLength = 16
    /// Small chunks keep keyboard and pointer input responsive while a file
    /// shares the connection.
    static let maximumChunkLength = 32 * 1_024
    /// Unacknowledged chunks a sender may have in flight.
    static let windowChunkCount = 4
    static let maximumNameByteCount = 255
    static let maximumDetailByteCount = 1_024
    static let maximumFileSize: UInt64 = 64 * 1_024 * 1_024 * 1_024
    static let maximumFilesPerRequest = 20
    static let digestLength = 32

    enum Kind: UInt8, CaseIterable, Sendable {
        /// Sender → receiver. Announces a file; the receiver accepts with an
        /// acknowledgement of zero bytes or declines with a result.
        case offer = 0x30
        /// Sender → receiver. The next bytes at `offset`.
        case chunk = 0x31
        /// Receiver → sender. Total bytes written; also grants window credit.
        case acknowledge = 0x32
        /// Sender → receiver. SHA-256 of the whole file after the last chunk.
        case complete = 0x33
        /// Either direction. Ends a transfer or a request.
        case result = 0x34
        /// iPhone or iPad → Mac. Asks the Mac to offer files.
        case request = 0x35
    }

    enum Status: UInt8, CaseIterable, Sendable {
        case completed = 0
        case cancelled = 1
        case declined = 2
        case failed = 3
        case integrityFailure = 4
        case disabled = 5
        case permissionRequired = 6
        case nothingSelected = 7
        case unsupportedItem = 8
        case insufficientSpace = 9
        case tooLarge = 10
    }

    enum RequestSource: UInt8, Sendable {
        /// The files currently selected in the Mac's frontmost Finder window.
        case finderSelection = 1
    }

    enum Message: Equatable, Sendable {
        case offer(id: Data, size: UInt64, name: String)
        case chunk(id: Data, offset: UInt64, data: Data)
        case acknowledge(id: Data, receivedBytes: UInt64)
        case complete(id: Data, sha256: Data)
        case result(id: Data, status: Status, detail: String)
        case request(id: Data, source: RequestSource)

        var kind: Kind {
            switch self {
            case .offer: .offer
            case .chunk: .chunk
            case .acknowledge: .acknowledge
            case .complete: .complete
            case .result: .result
            case .request: .request
            }
        }

        var transferID: Data {
            switch self {
            case let .offer(id, _, _), let .chunk(id, _, _), let .acknowledge(id, _),
                 let .complete(id, _), let .result(id, _, _), let .request(id, _):
                id
            }
        }
    }

    struct WireError: Error, LocalizedError, Equatable, Sendable {
        let reason: String
        var errorDescription: String? { "Malformed file transfer message: \(reason)" }
    }

    static func encode(_ message: Message) throws -> Data {
        var writer = Writer()
        try writer.writeIdentifier(message.transferID)
        switch message {
        case let .offer(_, size, name):
            guard size <= maximumFileSize else { throw WireError(reason: "file is too large") }
            writer.write(size)
            try writer.writeString(name, maximumByteCount: maximumNameByteCount, allowsEmpty: false)
        case let .chunk(_, offset, data):
            guard (1...maximumChunkLength).contains(data.count) else {
                throw WireError(reason: "chunk length is out of range")
            }
            writer.write(offset)
            writer.write(data)
        case let .acknowledge(_, receivedBytes):
            writer.write(receivedBytes)
        case let .complete(_, sha256):
            guard sha256.count == digestLength else { throw WireError(reason: "digest length") }
            writer.write(sha256)
        case let .result(_, status, detail):
            writer.write(status.rawValue)
            try writer.writeString(detail, maximumByteCount: maximumDetailByteCount, allowsEmpty: true)
        case let .request(_, source):
            writer.write(source.rawValue)
        }
        return writer.data
    }

    static func decode(kind rawKind: UInt8, payload: Data) throws -> Message {
        guard let kind = Kind(rawValue: rawKind) else { throw WireError(reason: "unknown kind \(rawKind)") }
        var reader = Reader(data: payload)
        let id = try reader.readData(count: identifierLength)
        let message: Message
        switch kind {
        case .offer:
            let size = try reader.readUInt64()
            guard size <= maximumFileSize else { throw WireError(reason: "file is too large") }
            let name = try reader.readString(maximumByteCount: maximumNameByteCount)
            guard !name.isEmpty else { throw WireError(reason: "empty name") }
            message = .offer(id: id, size: size, name: name)
        case .chunk:
            let offset = try reader.readUInt64()
            let data = try reader.readRemainingData()
            guard (1...maximumChunkLength).contains(data.count) else {
                throw WireError(reason: "chunk length is out of range")
            }
            return .chunk(id: id, offset: offset, data: data)
        case .acknowledge:
            message = .acknowledge(id: id, receivedBytes: try reader.readUInt64())
        case .complete:
            message = .complete(id: id, sha256: try reader.readData(count: digestLength))
        case .result:
            guard let status = Status(rawValue: try reader.readUInt8()) else {
                throw WireError(reason: "unknown status")
            }
            message = .result(id: id, status: status,
                              detail: try reader.readString(maximumByteCount: maximumDetailByteCount))
        case .request:
            guard let source = RequestSource(rawValue: try reader.readUInt8()) else {
                throw WireError(reason: "unknown request source")
            }
            message = .request(id: id, source: source)
        }
        try reader.requireEnd()
        return message
    }

    /// A receiver-side file name: a single path component without control
    /// characters, separators, or a leading dot, at most 255 UTF-8 bytes, and
    /// with its extension preserved where possible.
    static func sanitizedFileName(_ proposed: String) -> String {
        let lastComponent = proposed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var scalars = String.UnicodeScalarView()
        for scalar in lastComponent.unicodeScalars {
            if scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format
                || scalar == ":" {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "File" }

        guard name.utf8.count > maximumNameByteCount else { return name }
        let pathExtension = (name as NSString).pathExtension
        let suffix = pathExtension.isEmpty || pathExtension.utf8.count > 32 ? "" : "." + pathExtension
        var stem = String(name.dropLast(suffix.count))
        while stem.utf8.count + suffix.utf8.count > maximumNameByteCount { stem.removeLast() }
        return stem + suffix
    }

    /// The first free name in `directory`: `Report.pdf`, `Report 2.pdf`, ….
    static func uniqueDestination(for name: String, in directory: URL,
                                  fileManager: FileManager = .default) -> URL {
        let candidate = directory.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let pathExtension = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var index = 2
        while true {
            let numbered = pathExtension.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(pathExtension)"
            let url = directory.appendingPathComponent(numbered, isDirectory: false)
            if !fileManager.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    static func makeIdentifier() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<identifierLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private struct Writer {
        private(set) var data = Data()

        mutating func write(_ value: UInt8) { data.append(value) }
        mutating func write(_ value: UInt16) { data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init)) }
        mutating func write(_ value: UInt64) { data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init)) }
        mutating func write(_ value: Data) { data.append(value) }

        mutating func writeIdentifier(_ identifier: Data) throws {
            guard identifier.count == FileTransferWire.identifierLength else {
                throw WireError(reason: "identifier length")
            }
            write(identifier)
        }

        mutating func writeString(_ value: String, maximumByteCount: Int, allowsEmpty: Bool) throws {
            let bytes = Data(value.utf8)
            guard bytes.count <= maximumByteCount, allowsEmpty || !bytes.isEmpty else {
                throw WireError(reason: "string length")
            }
            write(UInt16(bytes.count))
            write(bytes)
        }
    }

    private struct Reader {
        let data: Data
        private var offset = 0

        init(data: Data) { self.data = data }

        mutating func readUInt8() throws -> UInt8 { try readData(count: 1)[0] }

        mutating func readUInt16() throws -> UInt16 {
            try readData(count: 2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        }

        mutating func readUInt64() throws -> UInt64 {
            try readData(count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        mutating func readData(count: Int) throws -> Data {
            guard count >= 0, offset <= data.count - count else { throw WireError(reason: "unexpected end") }
            let start = data.startIndex + offset
            offset += count
            return Data(data[start..<(start + count)])
        }

        mutating func readRemainingData() throws -> Data {
            try readData(count: data.count - offset)
        }

        mutating func readString(maximumByteCount: Int) throws -> String {
            let length = Int(try readUInt16())
            guard length <= maximumByteCount else { throw WireError(reason: "string exceeds limit") }
            guard let value = String(data: try readData(count: length), encoding: .utf8) else {
                throw WireError(reason: "string is not UTF-8")
            }
            return value
        }

        func requireEnd() throws {
            guard offset == data.count else { throw WireError(reason: "trailing bytes") }
        }
    }
}
