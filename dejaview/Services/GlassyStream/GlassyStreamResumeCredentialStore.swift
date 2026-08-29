import Foundation
import Security

struct GlassyStreamResumeCredential: Equatable, Sendable {
    let clientIdentifier: Data
    let resumeSecret: Data
}

protocol GlassyStreamResumeCredentialStoring: Sendable {
    func credential(savedMachineID: UUID,
                    hostIdentifier: Data) throws -> GlassyStreamResumeCredential?
    func save(_ credential: GlassyStreamResumeCredential,
              savedMachineID: UUID,
              hostIdentifier: Data) throws
    func removeCredential(savedMachineID: UUID,
                          hostIdentifier: Data) throws
}

/// Device-local resume storage. The account includes both identities so a
/// discovered host cannot receive a credential issued for another Mac.
struct GlassyStreamKeychainCredentialStore: GlassyStreamResumeCredentialStoring {
    private static let service = "dev.bunn.glassydesk.glassy-stream.resume.v1"
    private static let encodedLength = 56

    func credential(savedMachineID: UUID,
                    hostIdentifier: Data) throws -> GlassyStreamResumeCredential? {
        var query = baseQuery(savedMachineID: savedMachineID,
                              hostIdentifier: hostIdentifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw storeError(status)
        }
        return try decode(data)
    }

    func save(_ credential: GlassyStreamResumeCredential,
              savedMachineID: UUID,
              hostIdentifier: Data) throws {
        guard credential.clientIdentifier.count == GlassyStreamWire.identifierLength,
              credential.resumeSecret.count == GlassyStreamWire.resumeSecretLength else {
            throw GlassyStreamClientError.credentialStoreFailed(
                "The host returned a malformed resume credential."
            )
        }

        let query = baseQuery(savedMachineID: savedMachineID,
                              hostIdentifier: hostIdentifier)
        let value = encode(credential)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData as String: value,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw storeError(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = value
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw storeError(addStatus)
        }
    }

    func removeCredential(savedMachineID: UUID,
                          hostIdentifier: Data) throws {
        let status = SecItemDelete(
            baseQuery(savedMachineID: savedMachineID,
                      hostIdentifier: hostIdentifier) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw storeError(status)
        }
    }

    private func baseQuery(savedMachineID: UUID,
                           hostIdentifier: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(savedMachineID: savedMachineID,
                                               hostIdentifier: hostIdentifier),
            kSecAttrSynchronizable as String: false
        ]
    }

    private func account(savedMachineID: UUID,
                         hostIdentifier: Data) -> String {
        let hostHex = hostIdentifier.map { String(format: "%02x", $0) }.joined()
        return "\(savedMachineID.uuidString.lowercased()):\(hostHex)"
    }

    private func encode(_ credential: GlassyStreamResumeCredential) -> Data {
        var value = Data("GSRC".utf8)
        value.append(1)
        value.append(contentsOf: [0, 0, 0])
        value.append(credential.clientIdentifier)
        value.append(credential.resumeSecret)
        return value
    }

    private func decode(_ data: Data) throws -> GlassyStreamResumeCredential {
        guard data.count == Self.encodedLength,
              data.prefix(4) == Data("GSRC".utf8),
              data[data.startIndex + 4] == 1,
              data[(data.startIndex + 5)..<(data.startIndex + 8)].allSatisfy({ $0 == 0 }) else {
            throw GlassyStreamClientError.credentialStoreFailed(
                "The stored resume credential has an unsupported format."
            )
        }
        let clientStart = data.startIndex + 8
        let secretStart = clientStart + GlassyStreamWire.identifierLength
        return GlassyStreamResumeCredential(
            clientIdentifier: Data(data[clientStart..<secretStart]),
            resumeSecret: Data(data[secretStart..<data.endIndex])
        )
    }

    private func storeError(_ status: OSStatus) -> GlassyStreamClientError {
        let message = SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain status \(status)"
        return .credentialStoreFailed(message)
    }
}
