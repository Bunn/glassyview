import CryptoKit
import Foundation

/// iOS half of Glassy Host wire protocol v1. Keep constants and transcript
/// strings byte-for-byte aligned with `GlassyHost/Services/HostProtocol.swift`.
enum GlassyStreamWire {
    static let version: UInt8 = 1
    static let magic: UInt32 = 0x474C_5359 // "GLSY"
    static let headerLength = 20
    static let maximumHandshakePayloadLength = 64 * 1024
    static let maximumPayloadLength = 16 * 1024 * 1024
    static let identifierLength = 16
    static let nonceLength = 32
    static let publicKeyLength = 32
    static let proofLength = 32
    static let resumeSecretLength = 32
    static let authenticationTagLength = 16
    static let pairingCodeSymbolCount = 12

    struct Capabilities: OptionSet, Sendable {
        let rawValue: UInt32

        static let h264AVCC = Capabilities(rawValue: 1 << 0)
        static let encryptedMedia = Capabilities(rawValue: 1 << 1)
        static let directInput = Capabilities(rawValue: 1 << 2)
        static let streamQualityControl = Capabilities(rawValue: 1 << 3)
        static let cursorPositionUpdates = Capabilities(rawValue: 1 << 4)
    }

    enum MessageKind: UInt8, Sendable {
        case serverHello = 0x01
        case clientHello = 0x02
        case authenticationAccepted = 0x03
        case protocolError = 0x04
        case ping = 0x05
        case pong = 0x06
        case videoConfiguration = 0x10
        case videoAccessUnit = 0x11
        case keyFrameRequest = 0x12
        case streamQualityRequest = 0x13
        case cursorPositionSubscription = 0x14
        case cursorPosition = 0x15
        case pointerInput = 0x20
        case scrollInput = 0x21
        case keyInput = 0x22
        case textInput = 0x23
    }

    struct Flags: OptionSet, Sendable {
        let rawValue: UInt16

        static let encrypted = Flags(rawValue: 1 << 0)
        static let keyFrame = Flags(rawValue: 1 << 1)
    }

    enum AuthenticationMethod: UInt8, Sendable {
        case pairingCode = 1
        case resumeSecret = 2
    }

    struct Frame: Sendable {
        let kind: MessageKind
        let flags: Flags
        let sequence: UInt64
        let payload: Data
    }

    struct ServerHello: Sendable {
        let hostIdentifier: Data
        let serverNonce: Data
        let serverPublicKey: Data
        let pairingWindow: UInt64
        let pairingCodeLifetimeSeconds: UInt16
        let capabilities: UInt32
        let serverName: String
    }

    struct ClientHello: Sendable {
        let clientIdentifier: Data
        let clientNonce: Data
        let clientPublicKey: Data
        let authenticationMethod: AuthenticationMethod
        let pairingWindow: UInt64
        let clientName: String
        let proof: Data
    }

    struct AuthenticationAccepted: Sendable {
        let clientIdentifier: Data
        let resumeSecret: Data
        let serverTimeMilliseconds: UInt64
        let maximumMediaPayloadLength: UInt32
    }

    struct SessionMaterial: Sendable {
        let encryptionKey: SymmetricKey
        let serverToClientNoncePrefix: Data
        let clientToServerNoncePrefix: Data
    }

    static func encode(_ frame: Frame) throws -> Data {
        guard frame.payload.count <= maximumPayloadLength else {
            throw violation("payload exceeds the 16 MiB limit")
        }
        var writer = GlassyByteWriter(capacity: headerLength + frame.payload.count)
        writer.write(magic)
        writer.write(version)
        writer.write(frame.kind.rawValue)
        writer.write(frame.flags.rawValue)
        writer.write(frame.sequence)
        writer.write(UInt32(frame.payload.count))
        writer.write(frame.payload)
        return writer.data
    }

    static func decodeNextFrame(from buffer: inout Data,
                                maximumPayloadLength allowedLength: Int = maximumPayloadLength) throws -> Frame? {
        guard buffer.count >= headerLength else { return nil }
        var reader = GlassyByteReader(data: Data(buffer.prefix(headerLength)))
        guard try reader.readUInt32() == magic else {
            throw violation("invalid frame magic")
        }
        let remoteVersion = try reader.readUInt8()
        guard remoteVersion == version else {
            throw GlassyStreamClientError.unsupportedHostVersion(remoteVersion)
        }
        let rawKind = try reader.readUInt8()
        guard let kind = MessageKind(rawValue: rawKind) else {
            throw violation("unknown message type \(rawKind)")
        }
        let rawFlags = try reader.readUInt16()
        let knownFlags = Flags.encrypted.rawValue | Flags.keyFrame.rawValue
        guard rawFlags & ~knownFlags == 0 else {
            throw violation("unknown message flags \(rawFlags)")
        }
        let sequence = try reader.readUInt64()
        let payloadLength = Int(try reader.readUInt32())
        guard payloadLength <= min(allowedLength, maximumPayloadLength) else {
            throw violation("payload length \(payloadLength) exceeds the negotiated limit")
        }
        let frameLength = headerLength + payloadLength
        guard buffer.count >= frameLength else { return nil }

        let payloadStart = buffer.startIndex + headerLength
        let payloadEnd = payloadStart + payloadLength
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeFirst(frameLength)
        return Frame(kind: kind,
                     flags: Flags(rawValue: rawFlags),
                     sequence: sequence,
                     payload: payload)
    }

    static func decodeServerHello(_ data: Data) throws -> ServerHello {
        var reader = GlassyByteReader(data: data)
        let hello = ServerHello(
            hostIdentifier: try reader.readData(count: identifierLength),
            serverNonce: try reader.readData(count: nonceLength),
            serverPublicKey: try reader.readData(count: publicKeyLength),
            pairingWindow: try reader.readUInt64(),
            pairingCodeLifetimeSeconds: try reader.readUInt16(),
            capabilities: try reader.readUInt32(),
            serverName: try reader.readLengthPrefixedString(maximumByteCount: 255)
        )
        try reader.requireEnd()
        return hello
    }

    static func encodeClientHello(_ hello: ClientHello) throws -> Data {
        var data = try encodeClientHelloForTranscript(hello)
        guard hello.proof.count == proofLength else {
            throw violation("client proof is not \(proofLength) bytes")
        }
        data.append(hello.proof)
        return data
    }

    static func authenticationTranscript(serverHello: ServerHello,
                                         clientHello: ClientHello) throws -> Data {
        var transcript = Data("GlassyHost authentication transcript v1\0".utf8)
        transcript.append(try encodeServerHello(serverHello))
        transcript.append(try encodeClientHelloForTranscript(clientHello))
        return transcript
    }

    static func authenticationKey(sharedSecret: SharedSecret,
                                  credential: Data,
                                  transcript: Data) -> SymmetricKey {
        let transcriptHash = Data(SHA256.hash(data: transcript))
        var info = Data("GlassyHost authentication key v1\0".utf8)
        info.append(credential)
        return sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                    salt: transcriptHash,
                                                    sharedInfo: info,
                                                    outputByteCount: 32)
    }

    static func authenticationProof(authenticationKey: SymmetricKey,
                                    transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript,
                                             using: authenticationKey))
    }

    static func sessionMaterial(sharedSecret: SharedSecret,
                                credential: Data,
                                transcript: Data) -> SessionMaterial {
        let transcriptHash = Data(SHA256.hash(data: transcript))
        var info = Data("GlassyHost encrypted session v1\0".utf8)
        info.append(credential)
        let key = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                       salt: transcriptHash,
                                                       sharedInfo: info,
                                                       outputByteCount: 32)
        let serverDigest = HMAC<SHA256>.authenticationCode(
            for: Data("GlassyHost server-to-client nonce v1".utf8),
            using: key
        )
        let clientDigest = HMAC<SHA256>.authenticationCode(
            for: Data("GlassyHost client-to-server nonce v1".utf8),
            using: key
        )
        return SessionMaterial(encryptionKey: key,
                               serverToClientNoncePrefix: Data(serverDigest.prefix(4)),
                               clientToServerNoncePrefix: Data(clientDigest.prefix(4)))
    }

    static func seal(_ plaintext: Data,
                     kind: MessageKind,
                     flags: Flags,
                     sequence: UInt64,
                     material: SessionMaterial,
                     serverToClient: Bool) throws -> Data {
        let encryptedFlags = flags.union(.encrypted)
        let nonce = try makeNonce(prefix: serverToClient
                                  ? material.serverToClientNoncePrefix
                                  : material.clientToServerNoncePrefix,
                                  sequence: sequence)
        let aad = authenticatedAdditionalData(kind: kind,
                                              flags: encryptedFlags,
                                              sequence: sequence)
        let sealedBox = try AES.GCM.seal(plaintext,
                                         using: material.encryptionKey,
                                         nonce: nonce,
                                         authenticating: aad)
        var data = Data(capacity: sealedBox.ciphertext.count + sealedBox.tag.count)
        data.append(sealedBox.ciphertext)
        data.append(sealedBox.tag)
        return data
    }

    static func open(_ ciphertextAndTag: Data,
                     kind: MessageKind,
                     flags: Flags,
                     sequence: UInt64,
                     material: SessionMaterial,
                     serverToClient: Bool) throws -> Data {
        guard flags.contains(.encrypted),
              ciphertextAndTag.count >= authenticationTagLength else {
            throw violation("encrypted message is missing its authentication tag")
        }
        let nonce = try makeNonce(prefix: serverToClient
                                  ? material.serverToClientNoncePrefix
                                  : material.clientToServerNoncePrefix,
                                  sequence: sequence)
        let split = ciphertextAndTag.index(ciphertextAndTag.endIndex,
                                           offsetBy: -authenticationTagLength)
        let box = try AES.GCM.SealedBox(nonce: nonce,
                                        ciphertext: ciphertextAndTag[..<split],
                                        tag: ciphertextAndTag[split...])
        do {
            return try AES.GCM.open(
                box,
                using: material.encryptionKey,
                authenticating: authenticatedAdditionalData(kind: kind,
                                                             flags: flags,
                                                             sequence: sequence)
            )
        } catch {
            throw violation("message authentication failed")
        }
    }

    static func decodeAuthenticationAccepted(_ data: Data) throws -> AuthenticationAccepted {
        var reader = GlassyByteReader(data: data)
        let accepted = AuthenticationAccepted(
            clientIdentifier: try reader.readData(count: identifierLength),
            resumeSecret: try reader.readData(count: resumeSecretLength),
            serverTimeMilliseconds: try reader.readUInt64(),
            maximumMediaPayloadLength: try reader.readUInt32()
        )
        try reader.requireEnd()
        guard accepted.maximumMediaPayloadLength > 0,
              accepted.maximumMediaPayloadLength <= UInt32(maximumPayloadLength) else {
            throw violation("invalid maximum media payload length")
        }
        return accepted
    }

    static func decodeVideoConfiguration(_ data: Data) throws -> GlassyStreamVideoConfiguration {
        var reader = GlassyByteReader(data: data)
        let nalUnitHeaderLength = Int(try reader.readUInt8())
        let parameterSetCount = Int(try reader.readUInt8())
        guard try reader.readUInt16() == 0 else {
            throw violation("video configuration reserved bytes are nonzero")
        }
        guard (1...4).contains(nalUnitHeaderLength),
              (1...16).contains(parameterSetCount) else {
            throw violation("invalid H.264 configuration")
        }
        var parameterSets: [Data] = []
        parameterSets.reserveCapacity(parameterSetCount)
        for _ in 0..<parameterSetCount {
            let length = Int(try reader.readUInt32())
            guard length > 0, length <= maximumPayloadLength else {
                throw violation("invalid H.264 parameter-set length")
            }
            parameterSets.append(try reader.readData(count: length))
        }
        try reader.requireEnd()
        return GlassyStreamVideoConfiguration(
            nalUnitHeaderLength: nalUnitHeaderLength,
            parameterSets: parameterSets
        )
    }

    static func decodeVideoAccessUnit(_ data: Data,
                                      isKeyFrame: Bool) throws -> GlassyStreamVideoAccessUnit {
        guard data.count > 16 else {
            throw violation("empty H.264 access unit")
        }
        var reader = GlassyByteReader(data: data)
        let presentationNanoseconds = try reader.readInt64()
        let durationNanoseconds = try reader.readInt64()
        guard presentationNanoseconds >= 0,
              durationNanoseconds == -1 || durationNanoseconds >= 0 else {
            throw violation("invalid media timestamp")
        }
        let accessUnit = try reader.readData(count: data.count - 16)
        try reader.requireEnd()
        return GlassyStreamVideoAccessUnit(
            data: accessUnit,
            presentationTime: TimeInterval(presentationNanoseconds) / 1_000_000_000,
            duration: durationNanoseconds == -1
                ? nil
                : TimeInterval(durationNanoseconds) / 1_000_000_000,
            isKeyFrame: isKeyFrame
        )
    }

    static func decodeProtocolError(_ data: Data) -> String {
        do {
            var reader = GlassyByteReader(data: data)
            let code = try reader.readUInt16()
            let message = try reader.readLengthPrefixedString(maximumByteCount: 1_024)
            try reader.requireEnd()
            return message.isEmpty ? "Host error \(code)" : message
        } catch {
            return "The host rejected the protocol message."
        }
    }

    static func encodeKeyFrameRequest() -> Data {
        Data()
    }

    static func encodeStreamQualityRequest(_ quality: RemoteSessionQuality) -> Data {
        let preset: UInt8 = switch quality {
        case .dataSaver:
            0
        case .balanced:
            1
        case .best:
            2
        }

        var writer = GlassyByteWriter(capacity: 4)
        writer.write(preset)
        writer.write(Data(repeating: 0, count: 3))
        return writer.data
    }

    static func decodeStreamQualityRequest(_ data: Data) throws -> RemoteSessionQuality {
        var reader = GlassyByteReader(data: data)
        let preset = try reader.readUInt8()
        let reserved = try reader.readData(count: 3)
        guard reserved.allSatisfy({ $0 == 0 }) else {
            throw violation("stream quality reserved bytes are nonzero")
        }
        try reader.requireEnd()

        switch preset {
        case 0:
            return .dataSaver
        case 1:
            return .balanced
        case 2:
            return .best
        default:
            throw violation("stream quality preset is unknown")
        }
    }

    static func encodeCursorPositionSubscription() -> Data {
        Data([1, 0, 0, 0])
    }

    static func decodeCursorPosition(_ data: Data) throws -> GlassyStreamCursorPosition {
        var reader = GlassyByteReader(data: data)
        let position = GlassyStreamCursorPosition(
            x: try reader.readUInt16(),
            y: try reader.readUInt16()
        )
        try reader.requireEnd()
        return position
    }

    static func encodePointerInput(
        x: UInt16,
        y: UInt16,
        buttons: GlassyStreamPointerButtons
    ) throws -> Data {
        guard buttons.rawValue & ~UInt8(0x03) == 0 else {
            throw violation("pointer input contains an unknown button")
        }

        var writer = GlassyByteWriter(capacity: 6)
        writer.write(x)
        writer.write(y)
        writer.write(buttons.rawValue)
        writer.write(UInt8(0))
        return writer.data
    }

    static func encodeScrollInput(
        direction: GlassyStreamScrollDirection,
        steps: UInt16
    ) throws -> Data {
        guard (1...64).contains(steps) else {
            throw violation("scroll input steps must be between 1 and 64")
        }

        var writer = GlassyByteWriter(capacity: 4)
        writer.write(direction.rawValue)
        writer.write(UInt8(0))
        writer.write(steps)
        return writer.data
    }

    static func encodeKeyInput(keysym: UInt32, isDown: Bool) -> Data {
        var writer = GlassyByteWriter(capacity: 8)
        writer.write(keysym)
        writer.write(isDown ? UInt8(1) : UInt8(0))
        writer.write(Data(repeating: 0, count: 3))
        return writer.data
    }

    static func encodeTextInput(
        _ text: String,
        modifiers: GlassyStreamTextModifiers
    ) throws -> Data {
        guard modifiers.rawValue & ~UInt8(0x0F) == 0 else {
            throw violation("text input contains an unknown modifier")
        }

        let bytes = Data(text.utf8)
        guard (1...4_096).contains(bytes.count) else {
            throw violation("text input must contain 1 through 4096 UTF-8 bytes")
        }

        var writer = GlassyByteWriter(capacity: 4 + bytes.count)
        writer.write(modifiers.rawValue)
        writer.write(UInt8(0))
        writer.write(UInt16(bytes.count))
        writer.write(bytes)
        return writer.data
    }

    static func normalizedPairingCode(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        guard normalized.count == pairingCodeSymbolCount,
              normalized.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789").contains
              ) else {
            return nil
        }
        return normalized
    }

    private static func encodeServerHello(_ hello: ServerHello) throws -> Data {
        guard hello.hostIdentifier.count == identifierLength,
              hello.serverNonce.count == nonceLength,
              hello.serverPublicKey.count == publicKeyLength else {
            throw violation("invalid ServerHello field length")
        }
        var writer = GlassyByteWriter(capacity: 128)
        writer.write(hello.hostIdentifier)
        writer.write(hello.serverNonce)
        writer.write(hello.serverPublicKey)
        writer.write(hello.pairingWindow)
        writer.write(hello.pairingCodeLifetimeSeconds)
        writer.write(hello.capabilities)
        try writer.writeLengthPrefixedString(hello.serverName)
        return writer.data
    }

    private static func encodeClientHelloForTranscript(_ hello: ClientHello) throws -> Data {
        guard hello.clientIdentifier.count == identifierLength,
              hello.clientNonce.count == nonceLength,
              hello.clientPublicKey.count == publicKeyLength else {
            throw violation("invalid ClientHello field length")
        }
        var writer = GlassyByteWriter(capacity: 128)
        writer.write(hello.clientIdentifier)
        writer.write(hello.clientNonce)
        writer.write(hello.clientPublicKey)
        writer.write(hello.authenticationMethod.rawValue)
        writer.write(Data(repeating: 0, count: 3))
        writer.write(hello.pairingWindow)
        try writer.writeLengthPrefixedString(hello.clientName)
        return writer.data
    }

    private static func authenticatedAdditionalData(kind: MessageKind,
                                                    flags: Flags,
                                                    sequence: UInt64) -> Data {
        var writer = GlassyByteWriter(capacity: 16)
        writer.write(magic)
        writer.write(version)
        writer.write(kind.rawValue)
        writer.write(flags.rawValue)
        writer.write(sequence)
        return writer.data
    }

    private static func makeNonce(prefix: Data,
                                  sequence: UInt64) throws -> AES.GCM.Nonce {
        guard prefix.count == 4 else {
            throw violation("invalid session nonce prefix")
        }
        var writer = GlassyByteWriter(capacity: 12)
        writer.write(prefix)
        writer.write(sequence)
        return try AES.GCM.Nonce(data: writer.data)
    }

    private static func violation(_ message: String) -> GlassyStreamClientError {
        .protocolViolation(message)
    }
}

private struct GlassyByteWriter {
    private(set) var data: Data

    init(capacity: Int) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    mutating func write(_ value: UInt8) { data.append(value) }
    mutating func write(_ value: UInt16) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }
    mutating func write(_ value: UInt32) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }
    mutating func write(_ value: UInt64) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }
    mutating func write(_ value: Data) { data.append(value) }

    mutating func writeLengthPrefixedString(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= 255 else {
            throw GlassyStreamClientError.protocolViolation("name exceeds 255 UTF-8 bytes")
        }
        write(UInt16(bytes.count))
        write(bytes)
    }
}

private struct GlassyByteReader {
    let data: Data
    private(set) var offset = 0

    mutating func readUInt8() throws -> UInt8 {
        try readData(count: 1).first!
    }

    mutating func readUInt16() throws -> UInt16 {
        try readData(count: 2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        try readData(count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        try readData(count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw GlassyStreamClientError.protocolViolation("unexpected end of payload")
        }
        let start = data.startIndex + offset
        defer { offset += count }
        return Data(data[start..<(start + count)])
    }

    mutating func readLengthPrefixedString(maximumByteCount: Int) throws -> String {
        let length = Int(try readUInt16())
        guard length <= maximumByteCount else {
            throw GlassyStreamClientError.protocolViolation("string exceeds byte limit")
        }
        let bytes = try readData(count: length)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw GlassyStreamClientError.protocolViolation("string is not UTF-8")
        }
        return value
    }

    func requireEnd() throws {
        guard offset == data.count else {
            throw GlassyStreamClientError.protocolViolation("payload contains trailing bytes")
        }
    }
}
