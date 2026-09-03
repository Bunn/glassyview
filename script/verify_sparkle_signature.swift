import CryptoKit
import Foundation

// All arguments are public: download ZIP, signature, and the app's public key.
guard CommandLine.arguments.count == 4,
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let keyData = Data(base64Encoded: CommandLine.arguments[3]) else {
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard key.isValidSignature(signature, for: archive) else { exit(1) }
} catch {
    exit(1)
}
