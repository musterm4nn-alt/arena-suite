import Foundation
import Security
import SuiteDomain

/// Session material saved for one account: the principal it was verified for, and its cookies.
/// Passwords are never stored.
public struct StoredSession: Equatable, Sendable, Codable {
    public let format: Int
    public let principal: PrincipalIdentity
    public let cookies: Data

    public init(principal: PrincipalIdentity, cookies: Data) {
        self.format = 1
        self.principal = principal
        self.cookies = cookies
    }
}

public protocol SessionVault: Sendable {
    func load(account: AccountID) throws -> StoredSession?
    func save(_ session: StoredSession, account: AccountID) throws
    func delete(account: AccountID) throws
}

public enum SessionVaultError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case corrupt
}

/// One generic-password item per account (service `ArenaSuite.Account.Session.v1`, account = local
/// account UUID), not synchronized. Separate from the research proof's items.
///
/// Storage is the legacy file-based login Keychain: access without a prompt is limited to apps with
/// the same code-signing identity (ACL), and the item is never synced to iCloud. That Keychain
/// **ignores** `kSecAttrAccessible` (observed 2026-09-24), so "this device only" is *not* enforced:
/// the item travels with backups/migration of the login Keychain. The attribute is still set so it
/// takes effect if the vault moves to the data-protection Keychain, which needs a keychain-access-group
/// entitlement and provisioning profile (currently `errSecMissingEntitlement`, −34018).
public struct KeychainSessionVault: SessionVault {
    public let service: String

    public init(service: String = "ArenaSuite.Account.Session.v1") { self.service = service }

    private func query(_ account: AccountID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func load(account: AccountID) throws -> StoredSession? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SessionVaultError.keychain(status) }
        guard data.count <= 2 << 20, let session = try? JSONDecoder().decode(StoredSession.self, from: data),
            session.format == 1
        else { throw SessionVaultError.corrupt }
        return session
    }

    public func save(_ session: StoredSession, account: AccountID) throws {
        let data = try JSONEncoder().encode(session)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SessionVaultError.keychain(update) }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "Arena Suite session"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SessionVaultError.keychain(status) }
    }

    public func delete(account: AccountID) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SessionVaultError.keychain(status) }
    }
}
