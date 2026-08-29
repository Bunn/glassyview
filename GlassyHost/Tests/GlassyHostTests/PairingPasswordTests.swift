import Foundation
import Testing
@testable import GlassyHost

@Test("Pairing password PBKDF2 output matches the fixed protocol vector")
func pairingPasswordFixedKDFVector() throws {
    let hostIdentifier = Data(0..<16)
    let credential = try PairingPasswordPolicy.deriveCredential(
        from: "correct horse battery staple",
        hostIdentifier: hostIdentifier
    )

    #expect(
        credential.hexValue
            == "7860e2835faffc21a071c0b70458d3ec34e18527efcf7a06d2f902d5cb0b54f9"
    )
    #expect(credential.count == 32)
}

@Test("Pairing passwords use NFC without trimming or case folding")
func pairingPasswordNormalization() throws {
    let decomposed = "e\u{301}abcdefghijklmn"
    let composed = "éabcdefghijklmn"
    let hostIdentifier = Data(repeating: 0x42, count: HostProtocol.identifierLength)

    #expect(
        try PairingPasswordPolicy.normalizedPassword(decomposed)
            == PairingPasswordPolicy.normalizedPassword(composed)
    )
    #expect(
        try PairingPasswordPolicy.deriveCredential(
            from: decomposed,
            hostIdentifier: hostIdentifier
        ) == PairingPasswordPolicy.deriveCredential(
            from: composed,
            hostIdentifier: hostIdentifier
        )
    )

    let lower = "correct horse battery"
    let upper = "Correct horse battery"
    let leadingSpace = " correct horse battery"
    #expect(try PairingPasswordPolicy.normalizedPassword(leadingSpace).first == " ")
    #expect(
        try PairingPasswordPolicy.deriveCredential(
            from: lower,
            hostIdentifier: hostIdentifier
        ) != PairingPasswordPolicy.deriveCredential(
            from: upper,
            hostIdentifier: hostIdentifier
        )
    )
    #expect(
        try PairingPasswordPolicy.deriveCredential(
            from: lower,
            hostIdentifier: hostIdentifier
        ) != PairingPasswordPolicy.deriveCredential(
            from: leadingSpace,
            hostIdentifier: hostIdentifier
        )
    )
}

@Test("Pairing password policy enforces scalar, byte, and control bounds")
func pairingPasswordBounds() throws {
    #expect(throws: PairingPasswordPolicyError.tooShort) {
        _ = try PairingPasswordPolicy.normalizedPassword(String(repeating: "a", count: 14))
    }
    #expect(
        try PairingPasswordPolicy.normalizedPassword(String(repeating: "a", count: 15))
            .unicodeScalars.count == 15
    )
    #expect(
        try PairingPasswordPolicy.normalizedPassword(String(repeating: "🦆", count: 128))
            .utf8.count == 512
    )
    #expect(throws: PairingPasswordPolicyError.tooLong) {
        _ = try PairingPasswordPolicy.normalizedPassword(String(repeating: "a", count: 129))
    }
    #expect(throws: PairingPasswordPolicyError.containsControlCharacter) {
        _ = try PairingPasswordPolicy.normalizedPassword("correct horse\nbattery")
    }
    #expect(throws: PairingPasswordPolicyError.containsControlCharacter) {
        _ = try PairingPasswordPolicy.normalizedPassword("correct horse\u{0000}battery")
    }
}

@Test("Pairing password credential is bound to the host identity")
func pairingPasswordHostBinding() throws {
    let password = "correct horse battery"
    let firstHost = Data(repeating: 0x11, count: HostProtocol.identifierLength)
    let secondHost = Data(repeating: 0x22, count: HostProtocol.identifierLength)

    #expect(
        try PairingPasswordPolicy.deriveCredential(
            from: password,
            hostIdentifier: firstHost
        ) != PairingPasswordPolicy.deriveCredential(
            from: password,
            hostIdentifier: secondHost
        )
    )
    #expect(throws: PairingPasswordPolicyError.invalidHostIdentifier) {
        _ = try PairingPasswordPolicy.deriveCredential(
            from: password,
            hostIdentifier: Data(repeating: 0, count: 15)
        )
    }
}

@Test("Blocked pairing traffic does not extend the failure window")
func pairingAttemptLimitDoesNotExtendWhileBlocked() {
    var limiter = HostPairingAttemptLimiter()
    let start = Date(timeIntervalSince1970: 1_000)

    for _ in 0..<HostPairingAttemptLimiter.maximumFailures {
        let didRecord = limiter.recordFailureIfAllowed(at: start)
        #expect(didRecord)
    }
    let wasAllowedWhileBlocked = limiter.isAllowed(at: start.addingTimeInterval(30))
    let didExtendBlock = limiter.recordFailureIfAllowed(
        at: start.addingTimeInterval(30)
    )
    #expect(!wasAllowedWhileBlocked)
    #expect(!didExtendBlock)
    #expect(limiter.failureDates.count == HostPairingAttemptLimiter.maximumFailures)
    let isAllowedAfterWindow = limiter.isAllowed(at: start.addingTimeInterval(60))
    #expect(isAllowedAfterWindow)
}

private extension Data {
    var hexValue: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
