import Foundation
import Security

protocol SavedMachineRepository {
    func loadMachines() -> [SavedMachine]
    /// Like `loadMachines()`, but throws when the store can't be read instead of returning an empty list.
    func fetchMachines() throws -> [SavedMachine]
    func addMachine(_ machine: SavedMachine)
    func updateMachine(_ machine: SavedMachine)
    func deleteMachine(withID id: UUID)
    func loadRecentConnections(limit: Int) -> [ConnectionHistoryEntry]
    func startSession(withID id: UUID,
                      to machine: SavedMachine,
                      connectedAt: Date)
    func finishSession(withID id: UUID,
                       endedAt: Date,
                       outcome: ConnectionHistoryOutcome)
    func deleteRecentConnection(withID id: UUID)
    func clearRecentConnections()
    func password(for id: UUID) -> String?
    func setPassword(_ password: String, for id: UUID)
    func deletePassword(for id: UUID)
    func sessionPreferences(for id: UUID) -> SessionPreferences
    func setSessionPreferences(_ preferences: SessionPreferences, for id: UUID)
}

extension SavedMachineRepository {
    func fetchMachines() throws -> [SavedMachine] {
        loadMachines()
    }
}

struct UserDefaultsSavedMachineRepository: SavedMachineRepository {
    static let shared = UserDefaultsSavedMachineRepository()

    private let defaultsKey = "savedMachines"
    private let sessionPreferencesKeyPrefix = "savedMachineSessionPreferences."

    func loadMachines() -> [SavedMachine] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            AppLog.storage.info("No saved machines found in UserDefaults")
            return []
        }

        do {
            let machines = try JSONDecoder().decode([SavedMachine].self, from: data)
            AppLog.storage.info("Loaded \(machines.count, privacy: .public) saved machines")
            return machines
        } catch {
            AppLog.storage.error("Failed to decode saved machines: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func addMachine(_ machine: SavedMachine) {
        var machines = loadMachines()
        machines.append(machine)
        saveMachines(machines)
    }

    func updateMachine(_ machine: SavedMachine) {
        var machines = loadMachines()

        guard let index = machines.firstIndex(where: { $0.id == machine.id }) else {
            machines.append(machine)
            saveMachines(machines)
            return
        }

        machines[index] = machine
        saveMachines(machines)
    }

    func deleteMachine(withID id: UUID) {
        var machines = loadMachines()
        machines.removeAll { $0.id == id }
        saveMachines(machines)
        UserDefaults.standard.removeObject(forKey: sessionPreferencesKey(for: id))
    }

    func loadRecentConnections(limit: Int) -> [ConnectionHistoryEntry] {
        []
    }

    func startSession(withID id: UUID,
                      to machine: SavedMachine,
                      connectedAt: Date) {}

    func finishSession(withID id: UUID,
                       endedAt: Date,
                       outcome: ConnectionHistoryOutcome) {}

    func deleteRecentConnection(withID id: UUID) {}

    func clearRecentConnections() {}

    private func saveMachines(_ machines: [SavedMachine]) {
        do {
            let data = try JSONEncoder().encode(machines)
            UserDefaults.standard.set(data, forKey: defaultsKey)
            AppLog.storage.debug("Persisted \(machines.count, privacy: .public) saved machines")
        } catch {
            AppLog.storage.error("Failed to encode saved machines: \(error.localizedDescription, privacy: .public)")
        }
    }

    func password(for id: UUID) -> String? {
        KeychainPasswordStore.password(for: id)
    }

    func setPassword(_ password: String, for id: UUID) {
        KeychainPasswordStore.setPassword(password, for: id)
    }

    func deletePassword(for id: UUID) {
        KeychainPasswordStore.deletePassword(for: id)
    }

    func sessionPreferences(for id: UUID) -> SessionPreferences {
        guard let data = UserDefaults.standard.data(forKey: sessionPreferencesKey(for: id)) else {
            return .default
        }

        do {
            return try JSONDecoder().decode(SessionPreferences.self, from: data).normalized
        } catch {
            AppLog.storage.error("Failed to decode legacy session preferences id=\(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    func setSessionPreferences(_ preferences: SessionPreferences, for id: UUID) {
        do {
            let data = try JSONEncoder().encode(preferences.normalized)
            UserDefaults.standard.set(data, forKey: sessionPreferencesKey(for: id))
        } catch {
            AppLog.storage.error("Failed to encode legacy session preferences id=\(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sessionPreferencesKey(for id: UUID) -> String {
        sessionPreferencesKeyPrefix + id.uuidString
    }
}
private enum KeychainPasswordStore {
    private static let service = "com.example.dejaview.passwords"

    private static func baseQuery(for id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func setPassword(_ password: String, for id: UUID) {
        var query = baseQuery(for: id)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecSuccess {
            AppLog.storage.debug("Stored Keychain password for id=\(id.uuidString, privacy: .public)")
        } else {
            AppLog.storage.error("Failed to store Keychain password for id=\(id.uuidString, privacy: .public); status=\(status, privacy: .public)")
        }
    }

    static func password(for id: UUID) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?

        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data else {
            if status != errSecItemNotFound {
                AppLog.storage.error("Failed to read Keychain password for id=\(id.uuidString, privacy: .public); status=\(status, privacy: .public)")
            }

            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for id: UUID) {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            AppLog.storage.debug("Deleted Keychain password for id=\(id.uuidString, privacy: .public); status=\(status, privacy: .public)")
        } else {
            AppLog.storage.error("Failed to delete Keychain password for id=\(id.uuidString, privacy: .public); status=\(status, privacy: .public)")
        }
    }
}
