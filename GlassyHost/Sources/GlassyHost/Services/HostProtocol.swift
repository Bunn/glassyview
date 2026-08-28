import CryptoKit
import Foundation

/// The Glassy Host wire protocol.
///
/// Every TCP message starts with a fixed 20-byte header:
///
/// ```
///  0               4 5 6   8              16              20
/// +----------------+---+---+---------------+----------------+
/// | magic "GLSY"   |ver|typ| flags (BE16)  | sequence (BE64)|
/// +----------------+---+---+---------------+----------------+
/// | payload length (BE32)                                  |
/// +--------------------------------------------------------+
/// ```
///
/// Handshake messages are plaintext. Once authenticated, every message must
/// carry ``Flags/encrypted`` and its payload is AES-GCM ciphertext followed by
/// the 16-byte tag. The nonce is deterministic per session and direction:
/// `4-byte HKDF/HMAC prefix || 8-byte message sequence`. Header fields through
/// sequence are authenticated as additional data.
enum HostProtocol {
    static let bonjourServiceType = "_glassydesk._tcp"
    static let version: UInt8 = 1
    static let magic: UInt32 = 0x474C_5359 // "GLSY"
    static let headerLength = 20

    static let maximumHandshakePayloadLength = 64 * 1024
    static let maximumPayloadLength = 16 * 1024 * 1024
    static let pairingCodeLifetime: TimeInterval = 60

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
    }

    static let advertisedCapabilities: Capabilities = [
        .h264AVCC,
        .encryptedMedia,
        .directInput,
        .streamQualityControl
    ]

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
        /// First-use pairing. The client proves the short-lived code displayed
        /// by the host without transmitting the code itself.
        case pairingCode = 1

        /// Subsequent connections. The client proves the 256-bit resume secret
        /// issued inside the encrypted authentication-accepted message.
        case resumeSecret = 2
    }

    /// An allowlisted host capture/encoding preset. Lower raw values are more
    /// bandwidth-conscious so a shared stream can conservatively satisfy every
    /// authenticated viewer by selecting the minimum requested value.
    enum StreamQuality: UInt8, CaseIterable, Sendable {
        case dataSaver = 0
        case balanced = 1
        case best = 2
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

    struct PointerButtonMask: OptionSet, Equatable, Sendable {
        let rawValue: UInt8

        static let left = PointerButtonMask(rawValue: 1 << 0)
        static let right = PointerButtonMask(rawValue: 1 << 1)
    }

    struct PointerInput: Equatable, Sendable {
        let normalizedX: UInt16
        let normalizedY: UInt16
        let buttonMask: PointerButtonMask
    }

    enum ScrollDirection: UInt8, Equatable, Sendable {
        case up = 0
        case down = 1
        case left = 2
        case right = 3
    }

    struct ScrollInput: Equatable, Sendable {
        let direction: ScrollDirection
        let steps: UInt16
    }

    struct KeyInput: Equatable, Sendable {
        let keysym: UInt32
        let isDown: Bool
    }

    struct TextModifierMask: OptionSet, Equatable, Sendable {
        let rawValue: UInt8

        static let command = TextModifierMask(rawValue: 1 << 0)
        static let shift = TextModifierMask(rawValue: 1 << 1)
        static let option = TextModifierMask(rawValue: 1 << 2)
        static let control = TextModifierMask(rawValue: 1 << 3)
    }

    struct TextInput: Equatable, Sendable {
        let modifierMask: TextModifierMask
        let text: String
    }

    enum RemoteInputEvent: Equatable, Sendable {
        case pointer(PointerInput)
        case scroll(ScrollInput)
        case key(KeyInput)
        case text(TextInput)
    }

    struct SessionMaterial: Sendable {
        let encryptionKey: SymmetricKey
        let serverToClientNoncePrefix: Data
        let clientToServerNoncePrefix: Data
    }

    enum ProtocolError: Swift.Error, LocalizedError, Sendable {
        case invalidMagic
        case unsupportedVersion(UInt8)
        case unknownMessageKind(UInt8)
        case invalidFlags(UInt16)
        case payloadTooLarge(Int)
        case malformedPayload(String)
        case invalidAuthentication
        case invalidCiphertext

        var errorDescription: String? {
            switch self {
            case .invalidMagic:
                "Invalid Glassy Host frame magic."
            case let .unsupportedVersion(version):
                "Unsupported Glassy Host protocol version \(version)."
            case let .unknownMessageKind(kind):
                "Unknown Glassy Host message type \(kind)."
            case let .invalidFlags(flags):
                "Invalid Glassy Host message flags \(flags)."
            case let .payloadTooLarge(length):
                "Glassy Host payload exceeds the limit (\(length) bytes)."
            case let .malformedPayload(reason):
                "Malformed Glassy Host payload: \(reason)"
            case .invalidAuthentication:
                "Authentication failed."
            case .invalidCiphertext:
                "Encrypted Glassy Host payload could not be authenticated."
            }
        }
    }

    // MARK: - Framing

    static func encode(_ frame: Frame) throws -> Data {
        guard frame.payload.count <= maximumPayloadLength else {
            throw ProtocolError.payloadTooLarge(frame.payload.count)
        }

        var writer = ByteWriter(capacity: headerLength + frame.payload.count)
        writer.write(magic)
        writer.write(version)
        writer.write(frame.kind.rawValue)
        writer.write(frame.flags.rawValue)
        writer.write(frame.sequence)
        writer.write(UInt32(frame.payload.count))
        writer.write(frame.payload)
        return writer.data
    }

    /// Removes and returns one complete frame. Returns `nil` when more TCP
    /// bytes are required and throws as soon as a complete header is invalid.
    static func decodeNextFrame(from buffer: inout Data,
                                maximumPayloadLength allowedPayloadLength: Int = maximumPayloadLength) throws -> Frame? {
        guard buffer.count >= headerLength else { return nil }

        var headerReader = ByteReader(data: buffer.prefixData(headerLength))
        guard try headerReader.readUInt32() == magic else {
            throw ProtocolError.invalidMagic
        }

        let receivedVersion = try headerReader.readUInt8()
        guard receivedVersion == version else {
            throw ProtocolError.unsupportedVersion(receivedVersion)
        }

        let rawKind = try headerReader.readUInt8()
        guard let kind = MessageKind(rawValue: rawKind) else {
            throw ProtocolError.unknownMessageKind(rawKind)
        }

        let rawFlags = try headerReader.readUInt16()
        let knownFlags = Flags.encrypted.rawValue | Flags.keyFrame.rawValue
        guard rawFlags & ~knownFlags == 0 else {
            throw ProtocolError.invalidFlags(rawFlags)
        }

        let sequence = try headerReader.readUInt64()
        let payloadLength = Int(try headerReader.readUInt32())
        guard payloadLength <= min(allowedPayloadLength, maximumPayloadLength) else {
            throw ProtocolError.payloadTooLarge(payloadLength)
        }

        let frameLength = headerLength + payloadLength
        guard buffer.count >= frameLength else { return nil }

        let payload = buffer.subdata(in: headerLength..<frameLength)
        buffer.removeSubrange(0..<frameLength)
        return Frame(kind: kind,
                     flags: Flags(rawValue: rawFlags),
                     sequence: sequence,
                     payload: payload)
    }

    static func authenticatedAdditionalData(kind: MessageKind,
                                            flags: Flags,
                                            sequence: UInt64) -> Data {
        var writer = ByteWriter(capacity: 16)
        writer.write(magic)
        writer.write(version)
        writer.write(kind.rawValue)
        writer.write(flags.rawValue)
        writer.write(sequence)
        return writer.data
    }

    // MARK: - Handshake payloads

    static func encodeServerHello(_ hello: ServerHello) throws -> Data {
        try requireLength(hello.hostIdentifier, identifierLength, field: "host identifier")
        try requireLength(hello.serverNonce, nonceLength, field: "server nonce")
        try requireLength(hello.serverPublicKey, publicKeyLength, field: "server public key")
        guard hello.serverName.utf8.count <= 255 else {
            throw ProtocolError.malformedPayload("server name exceeds 255 UTF-8 bytes")
        }

        var writer = ByteWriter(capacity: 128)
        writer.write(hello.hostIdentifier)
        writer.write(hello.serverNonce)
        writer.write(hello.serverPublicKey)
        writer.write(hello.pairingWindow)
        writer.write(hello.pairingCodeLifetimeSeconds)
        writer.write(hello.capabilities)
        try writer.writeLengthPrefixedString(hello.serverName)
        return writer.data
    }

    static func decodeServerHello(_ data: Data) throws -> ServerHello {
        var reader = ByteReader(data: data)
        let value = ServerHello(
            hostIdentifier: try reader.readData(count: identifierLength),
            serverNonce: try reader.readData(count: nonceLength),
            serverPublicKey: try reader.readData(count: publicKeyLength),
            pairingWindow: try reader.readUInt64(),
            pairingCodeLifetimeSeconds: try reader.readUInt16(),
            capabilities: try reader.readUInt32(),
            serverName: try reader.readLengthPrefixedString(maximumByteCount: 255)
        )
        try reader.requireEnd()
        return value
    }

    static func encodeClientHello(_ hello: ClientHello) throws -> Data {
        var data = try encodeClientHelloForTranscript(hello)
        try requireLength(hello.proof, proofLength, field: "client proof")
        data.append(hello.proof)
        return data
    }

    static func decodeClientHello(_ data: Data) throws -> ClientHello {
        var reader = ByteReader(data: data)
        let clientIdentifier = try reader.readData(count: identifierLength)
        let clientNonce = try reader.readData(count: nonceLength)
        let clientPublicKey = try reader.readData(count: publicKeyLength)
        let rawMethod = try reader.readUInt8()
        guard let method = AuthenticationMethod(rawValue: rawMethod) else {
            throw ProtocolError.malformedPayload("unknown authentication method")
        }
        let reserved = try reader.readData(count: 3)
        guard reserved.allSatisfy({ $0 == 0 }) else {
            throw ProtocolError.malformedPayload("reserved ClientHello bytes must be zero")
        }
        let pairingWindow = try reader.readUInt64()
        let clientName = try reader.readLengthPrefixedString(maximumByteCount: 255)
        let proof = try reader.readData(count: proofLength)
        try reader.requireEnd()

        return ClientHello(clientIdentifier: clientIdentifier,
                           clientNonce: clientNonce,
                           clientPublicKey: clientPublicKey,
                           authenticationMethod: method,
                           pairingWindow: pairingWindow,
                           clientName: clientName,
                           proof: proof)
    }

    static func encodeAuthenticationAccepted(_ accepted: AuthenticationAccepted) throws -> Data {
        try requireLength(accepted.clientIdentifier, identifierLength, field: "client identifier")
        try requireLength(accepted.resumeSecret, resumeSecretLength, field: "resume secret")

        var writer = ByteWriter(capacity: 64)
        writer.write(accepted.clientIdentifier)
        writer.write(accepted.resumeSecret)
        writer.write(accepted.serverTimeMilliseconds)
        writer.write(accepted.maximumMediaPayloadLength)
        return writer.data
    }

    static func encodeError(code: UInt16, message: String) throws -> Data {
        var writer = ByteWriter(capacity: 128)
        writer.write(code)
        try writer.writeLengthPrefixedString(message)
        return writer.data
    }

    // MARK: - Direct input payloads

    static func encodePointerInput(_ input: PointerInput) throws -> Data {
        let knownButtons = PointerButtonMask.left.rawValue | PointerButtonMask.right.rawValue
        guard input.buttonMask.rawValue & ~knownButtons == 0 else {
            throw ProtocolError.malformedPayload("pointer button mask contains unknown bits")
        }

        var writer = ByteWriter(capacity: 6)
        writer.write(input.normalizedX)
        writer.write(input.normalizedY)
        writer.write(input.buttonMask.rawValue)
        writer.write(UInt8(0))
        return writer.data
    }

    static func decodePointerInput(_ data: Data) throws -> PointerInput {
        var reader = ByteReader(data: data)
        let normalizedX = try reader.readUInt16()
        let normalizedY = try reader.readUInt16()
        let rawButtons = try reader.readUInt8()
        let knownButtons = PointerButtonMask.left.rawValue | PointerButtonMask.right.rawValue
        guard rawButtons & ~knownButtons == 0 else {
            throw ProtocolError.malformedPayload("pointer button mask contains unknown bits")
        }
        guard try reader.readUInt8() == 0 else {
            throw ProtocolError.malformedPayload("reserved PointerInput byte must be zero")
        }
        try reader.requireEnd()
        return PointerInput(normalizedX: normalizedX,
                            normalizedY: normalizedY,
                            buttonMask: PointerButtonMask(rawValue: rawButtons))
    }

    static func encodeScrollInput(_ input: ScrollInput) throws -> Data {
        guard (1...64).contains(input.steps) else {
            throw ProtocolError.malformedPayload("scroll steps must be 1...64")
        }

        var writer = ByteWriter(capacity: 4)
        writer.write(input.direction.rawValue)
        writer.write(UInt8(0))
        writer.write(input.steps)
        return writer.data
    }

    static func decodeScrollInput(_ data: Data) throws -> ScrollInput {
        var reader = ByteReader(data: data)
        let rawDirection = try reader.readUInt8()
        guard let direction = ScrollDirection(rawValue: rawDirection) else {
            throw ProtocolError.malformedPayload("unknown scroll direction")
        }
        guard try reader.readUInt8() == 0 else {
            throw ProtocolError.malformedPayload("reserved ScrollInput byte must be zero")
        }
        let steps = try reader.readUInt16()
        guard (1...64).contains(steps) else {
            throw ProtocolError.malformedPayload("scroll steps must be 1...64")
        }
        try reader.requireEnd()
        return ScrollInput(direction: direction, steps: steps)
    }

    static func encodeKeyInput(_ input: KeyInput) -> Data {
        var writer = ByteWriter(capacity: 8)
        writer.write(input.keysym)
        writer.write(input.isDown ? UInt8(1) : UInt8(0))
        writer.write(Data(repeating: 0, count: 3))
        return writer.data
    }

    static func decodeKeyInput(_ data: Data) throws -> KeyInput {
        var reader = ByteReader(data: data)
        let keysym = try reader.readUInt32()
        let rawIsDown = try reader.readUInt8()
        guard rawIsDown <= 1 else {
            throw ProtocolError.malformedPayload("key state must be zero or one")
        }
        let reserved = try reader.readData(count: 3)
        guard reserved.allSatisfy({ $0 == 0 }) else {
            throw ProtocolError.malformedPayload("reserved KeyInput bytes must be zero")
        }
        try reader.requireEnd()
        return KeyInput(keysym: keysym, isDown: rawIsDown == 1)
    }

    static func encodeTextInput(_ input: TextInput) throws -> Data {
        let knownModifiers = TextModifierMask.command.rawValue
            | TextModifierMask.shift.rawValue
            | TextModifierMask.option.rawValue
            | TextModifierMask.control.rawValue
        guard input.modifierMask.rawValue & ~knownModifiers == 0 else {
            throw ProtocolError.malformedPayload("text modifier mask contains unknown bits")
        }

        let bytes = Data(input.text.utf8)
        guard (1...4096).contains(bytes.count) else {
            throw ProtocolError.malformedPayload("text must contain 1...4096 UTF-8 bytes")
        }

        var writer = ByteWriter(capacity: 4 + bytes.count)
        writer.write(input.modifierMask.rawValue)
        writer.write(UInt8(0))
        writer.write(UInt16(bytes.count))
        writer.write(bytes)
        return writer.data
    }

    static func decodeTextInput(_ data: Data) throws -> TextInput {
        var reader = ByteReader(data: data)
        let rawModifiers = try reader.readUInt8()
        let knownModifiers = TextModifierMask.command.rawValue
            | TextModifierMask.shift.rawValue
            | TextModifierMask.option.rawValue
            | TextModifierMask.control.rawValue
        guard rawModifiers & ~knownModifiers == 0 else {
            throw ProtocolError.malformedPayload("text modifier mask contains unknown bits")
        }
        guard try reader.readUInt8() == 0 else {
            throw ProtocolError.malformedPayload("reserved TextInput byte must be zero")
        }
        let byteLength = Int(try reader.readUInt16())
        guard (1...4096).contains(byteLength) else {
            throw ProtocolError.malformedPayload("text must contain 1...4096 UTF-8 bytes")
        }
        let bytes = try reader.readData(count: byteLength)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ProtocolError.malformedPayload("text is not UTF-8")
        }
        try reader.requireEnd()
        return TextInput(modifierMask: TextModifierMask(rawValue: rawModifiers),
                         text: text)
    }

    static func decodeRemoteInput(kind: MessageKind, payload: Data) throws -> RemoteInputEvent {
        switch kind {
        case .pointerInput:
            .pointer(try decodePointerInput(payload))
        case .scrollInput:
            .scroll(try decodeScrollInput(payload))
        case .keyInput:
            .key(try decodeKeyInput(payload))
        case .textInput:
            .text(try decodeTextInput(payload))
        default:
            throw ProtocolError.malformedPayload("message is not a direct input event")
        }
    }

    static func decodeKeyFrameRequest(_ data: Data) throws {
        guard data.isEmpty else {
            throw ProtocolError.malformedPayload("keyframe request payload must be empty")
        }
    }

    static func encodeStreamQualityRequest(_ quality: StreamQuality) -> Data {
        Data([quality.rawValue, 0, 0, 0])
    }

    static func decodeStreamQualityRequest(_ data: Data) throws -> StreamQuality {
        var reader = ByteReader(data: data)
        let rawQuality = try reader.readUInt8()
        guard let quality = StreamQuality(rawValue: rawQuality) else {
            throw ProtocolError.malformedPayload("unknown stream quality")
        }
        let reserved = try reader.readData(count: 3)
        guard reserved.allSatisfy({ $0 == 0 }) else {
            throw ProtocolError.malformedPayload(
                "reserved stream quality request bytes must be zero"
            )
        }
        try reader.requireEnd()
        return quality
    }

    /// The exact transcript authenticated by `ClientHello.proof`. The proof
    /// itself is deliberately excluded.
    static func authenticationTranscript(serverHello: ServerHello,
                                         clientHello: ClientHello) throws -> Data {
        var transcript = Data("GlassyHost authentication transcript v1\0".utf8)
        transcript.append(try encodeServerHello(serverHello))
        transcript.append(try encodeClientHelloForTranscript(clientHello))
        return transcript
    }

    private static func encodeClientHelloForTranscript(_ hello: ClientHello) throws -> Data {
        try requireLength(hello.clientIdentifier, identifierLength, field: "client identifier")
        try requireLength(hello.clientNonce, nonceLength, field: "client nonce")
        try requireLength(hello.clientPublicKey, publicKeyLength, field: "client public key")
        guard hello.clientName.utf8.count <= 255 else {
            throw ProtocolError.malformedPayload("client name exceeds 255 UTF-8 bytes")
        }

        var writer = ByteWriter(capacity: 128)
        writer.write(hello.clientIdentifier)
        writer.write(hello.clientNonce)
        writer.write(hello.clientPublicKey)
        writer.write(hello.authenticationMethod.rawValue)
        writer.write(Data(repeating: 0, count: 3))
        writer.write(hello.pairingWindow)
        try writer.writeLengthPrefixedString(hello.clientName)
        return writer.data
    }

    // MARK: - Authentication and encryption

    static func pairingWindow(at date: Date) -> UInt64 {
        UInt64(max(0, floor(date.timeIntervalSince1970 / pairingCodeLifetime)))
    }

    static func pairingCode(rootSecret: SymmetricKey, window: UInt64) -> String {
        var material = Data("GlassyHost pairing code v1\0".utf8)
        var writer = ByteWriter(capacity: 8)
        writer.write(window)
        material.append(writer.data)
        let digest = HMAC<SHA256>.authenticationCode(for: material, using: rootSecret)
        let bytes = Array(digest.prefix(8))
        let integer = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        // Twelve Base32 characters retain 60 bits. This is still compact enough
        // to type, while resisting offline guessing if an active LAN attacker
        // substitutes an ephemeral key during first-use pairing.
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let symbols = (0..<pairingCodeSymbolCount).map { index -> Character in
            let shift = UInt64(59 - (index * 5))
            return alphabet[Int((integer >> shift) & 0x1F)]
        }
        return String(symbols)
    }

    static func pairingCodeDisplayValue(_ value: String) -> String {
        guard value.count == pairingCodeSymbolCount else { return value }
        let symbols = Array(value)
        return stride(from: 0, to: symbols.count, by: 4)
            .map { String(symbols[$0..<min($0 + 4, symbols.count)]) }
            .joined(separator: "-")
    }

    static func resumeSecret(rootSecret: SymmetricKey,
                             clientIdentifier: Data) throws -> Data {
        try requireLength(clientIdentifier, identifierLength, field: "client identifier")
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: rootSecret,
            salt: clientIdentifier,
            info: Data("GlassyHost client resume secret v1".utf8),
            outputByteCount: resumeSecretLength
        )
        return key.withUnsafeBytes { Data($0) }
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

    static func isValidProof(_ proof: Data,
                             authenticationKey: SymmetricKey,
                             transcript: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof,
                                               authenticating: transcript,
                                               using: authenticationKey)
    }

    static func sessionMaterial(sharedSecret: SharedSecret,
                                credential: Data,
                                transcript: Data) -> SessionMaterial {
        let transcriptHash = Data(SHA256.hash(data: transcript))
        var info = Data("GlassyHost encrypted session v1\0".utf8)
        info.append(credential)
        let encryptionKey = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                                 salt: transcriptHash,
                                                                 sharedInfo: info,
                                                                 outputByteCount: 32)

        let serverDigest = HMAC<SHA256>.authenticationCode(
            for: Data("GlassyHost server-to-client nonce v1".utf8),
            using: encryptionKey
        )
        let clientDigest = HMAC<SHA256>.authenticationCode(
            for: Data("GlassyHost client-to-server nonce v1".utf8),
            using: encryptionKey
        )
        return SessionMaterial(encryptionKey: encryptionKey,
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
        let prefix = serverToClient
            ? material.serverToClientNoncePrefix
            : material.clientToServerNoncePrefix
        let nonce = try makeNonce(prefix: prefix, sequence: sequence)
        let aad = authenticatedAdditionalData(kind: kind,
                                              flags: encryptedFlags,
                                              sequence: sequence)
        let box = try AES.GCM.seal(plaintext,
                                   using: material.encryptionKey,
                                   nonce: nonce,
                                   authenticating: aad)
        var payload = Data(capacity: box.ciphertext.count + box.tag.count)
        payload.append(box.ciphertext)
        payload.append(box.tag)
        return payload
    }

    static func open(_ ciphertextAndTag: Data,
                     kind: MessageKind,
                     flags: Flags,
                     sequence: UInt64,
                     material: SessionMaterial,
                     serverToClient: Bool) throws -> Data {
        guard flags.contains(.encrypted),
              ciphertextAndTag.count >= authenticationTagLength else {
            throw ProtocolError.invalidCiphertext
        }

        let prefix = serverToClient
            ? material.serverToClientNoncePrefix
            : material.clientToServerNoncePrefix
        let nonce = try makeNonce(prefix: prefix, sequence: sequence)
        let tagStart = ciphertextAndTag.count - authenticationTagLength
        let ciphertext = ciphertextAndTag.prefixData(tagStart)
        let tag = ciphertextAndTag.subdata(in: tagStart..<ciphertextAndTag.count)
        let aad = authenticatedAdditionalData(kind: kind,
                                              flags: flags,
                                              sequence: sequence)

        do {
            let box = try AES.GCM.SealedBox(nonce: nonce,
                                            ciphertext: ciphertext,
                                            tag: tag)
            return try AES.GCM.open(box,
                                    using: material.encryptionKey,
                                    authenticating: aad)
        } catch {
            throw ProtocolError.invalidCiphertext
        }
    }

    private static func makeNonce(prefix: Data,
                                  sequence: UInt64) throws -> AES.GCM.Nonce {
        guard prefix.count == 4 else {
            throw ProtocolError.malformedPayload("invalid session nonce prefix")
        }
        var writer = ByteWriter(capacity: 12)
        writer.write(prefix)
        writer.write(sequence)
        return try AES.GCM.Nonce(data: writer.data)
    }

    // MARK: - Media payloads

    /// Encodes the H.264 parameter sets. Payload layout is:
    /// `NAL-length-field-bytes:u8, set-count:u8, reserved:u16`, followed by
    /// `length:u32 + bytes` for every SPS/PPS parameter set.
    static func encodeVideoConfiguration(parameterSets: [Data],
                                         nalUnitHeaderLength: Int) throws -> Data {
        guard (1...4).contains(nalUnitHeaderLength) else {
            throw ProtocolError.malformedPayload("NAL length field must be 1...4 bytes")
        }
        guard !parameterSets.isEmpty, parameterSets.count <= 16 else {
            throw ProtocolError.malformedPayload("expected 1...16 H.264 parameter sets")
        }

        var writer = ByteWriter(capacity: parameterSets.reduce(4) { $0 + 4 + $1.count })
        writer.write(UInt8(nalUnitHeaderLength))
        writer.write(UInt8(parameterSets.count))
        writer.write(UInt16(0))
        for parameterSet in parameterSets {
            guard parameterSet.count <= maximumPayloadLength else {
                throw ProtocolError.payloadTooLarge(parameterSet.count)
            }
            writer.write(UInt32(parameterSet.count))
            writer.write(parameterSet)
        }
        return writer.data
    }

    /// Encodes one AVCC access unit. Payload layout is:
    /// `presentation-time-ns:i64, duration-ns:i64 (-1 means unknown), AVCC...`.
    /// Keyframe state is carried in the frame header's `keyFrame` flag.
    static func encodeVideoAccessUnit(_ avccData: Data,
                                      presentationTimeSeconds: Double,
                                      durationSeconds: Double?) throws -> Data {
        let maximumTimeSeconds = Double(Int64.max) / 1_000_000_000
        guard presentationTimeSeconds.isFinite,
              presentationTimeSeconds >= 0,
              presentationTimeSeconds <= maximumTimeSeconds else {
            throw ProtocolError.malformedPayload("presentation time must be finite and nonnegative")
        }
        if let durationSeconds {
            guard durationSeconds.isFinite,
                  durationSeconds >= 0,
                  durationSeconds <= maximumTimeSeconds else {
                throw ProtocolError.malformedPayload("duration must be finite and nonnegative")
            }
        }
        // The outer encrypted frame adds a 16-byte AES-GCM tag.
        guard avccData.count + 16 + authenticationTagLength <= maximumPayloadLength else {
            throw ProtocolError.payloadTooLarge(avccData.count + 16 + authenticationTagLength)
        }

        let presentationNanoseconds = Int64((presentationTimeSeconds * 1_000_000_000).rounded())
        let durationNanoseconds = durationSeconds.map {
            Int64(($0 * 1_000_000_000).rounded())
        } ?? -1

        var writer = ByteWriter(capacity: 16 + avccData.count)
        writer.write(presentationNanoseconds)
        writer.write(durationNanoseconds)
        writer.write(avccData)
        return writer.data
    }

    // MARK: - Helpers

    private static func requireLength(_ data: Data,
                                      _ expectedLength: Int,
                                      field: String) throws {
        guard data.count == expectedLength else {
            throw ProtocolError.malformedPayload(
                "\(field) must be \(expectedLength) bytes, got \(data.count)"
            )
        }
    }
}

private struct ByteWriter {
    private(set) var data: Data

    init(capacity: Int) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    mutating func write(_ value: UInt8) {
        data.append(value)
    }

    mutating func write(_ value: UInt16) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    mutating func write(_ value: UInt32) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    mutating func write(_ value: UInt64) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    mutating func write(_ value: Int64) {
        write(UInt64(bitPattern: value))
    }

    mutating func write(_ value: Data) {
        data.append(value)
    }

    mutating func writeLengthPrefixedString(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= UInt16.max else {
            throw HostProtocol.ProtocolError.malformedPayload("string is too long")
        }
        write(UInt16(bytes.count))
        write(bytes)
    }
}

private struct ByteReader {
    let data: Data
    private(set) var offset = 0

    mutating func readUInt8() throws -> UInt8 {
        let bytes = try readData(count: 1)
        return bytes[bytes.startIndex]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw HostProtocol.ProtocolError.malformedPayload("unexpected end of data")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readLengthPrefixedString(maximumByteCount: Int) throws -> String {
        let length = Int(try readUInt16())
        guard length <= maximumByteCount else {
            throw HostProtocol.ProtocolError.malformedPayload("string exceeds byte limit")
        }
        let bytes = try readData(count: length)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw HostProtocol.ProtocolError.malformedPayload("string is not UTF-8")
        }
        return value
    }

    func requireEnd() throws {
        guard offset == data.count else {
            throw HostProtocol.ProtocolError.malformedPayload("trailing bytes")
        }
    }
}

private extension Data {
    func prefixData(_ count: Int) -> Data {
        Data(prefix(count))
    }
}
