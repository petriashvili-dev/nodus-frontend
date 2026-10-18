import Foundation
import Security

nonisolated struct AuthTokens: Codable, Sendable, Equatable {
    var userId: UUID
    var accessToken: String
    var accessTokenExpiresAt: Date
    var refreshToken: String
    var refreshTokenExpiresAt: Date
}

/// What the device remembers about its account between launches.
nonisolated struct StoredSession: Codable, Sendable, Equatable {
    var tokens: AuthTokens
    /// An anonymous account has no way back once its session is lost, so
    /// losing it is handled differently from an email account.
    var isAnonymous: Bool
}

/// Secrets live only in the Keychain (AGENTS.md); tests use an in-memory store.
nonisolated protocol SecureStore: Sendable {
    func loadSession() throws -> StoredSession?
    func saveSession(_ session: StoredSession) throws
    func clearSession() throws
    /// Generated once per install and sent as `installation_id`.
    func installationId() throws -> UUID
}

nonisolated enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

nonisolated struct KeychainStore: SecureStore {
    private let service = "app.nodus.auth"

    func loadSession() throws -> StoredSession? {
        guard let data = try read(account: "session") else { return nil }
        return try APICoding.decoder.decode(StoredSession.self, from: data)
    }

    func saveSession(_ session: StoredSession) throws {
        try write(APICoding.encoder.encode(session), account: "session")
    }

    func clearSession() throws {
        try delete(account: "session")
    }

    func installationId() throws -> UUID {
        if let data = try read(account: "installation_id"),
           let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) {
            return id
        }
        let id = UUID()
        try write(Data(id.uuidString.utf8), account: "installation_id")
        return id
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        // Readable after the first unlock so notification actions and Siri
        // can sync from the background; never leaves this device.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
