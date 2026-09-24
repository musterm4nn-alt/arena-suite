import Foundation
import Security

public protocol ResearchSessionStoring: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

/// A single explicitly authorized research slot, separate from production account storage.
public struct KeychainResearchSessionStore: ResearchSessionStoring {
    public init() {}
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ArenaSuite.NativeAuthProof.Session.v1",
            kSecAttrAccount as String: "single-research-session",
            kSecAttrSynchronizable as String: false,
        ]
    }
    public func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ResearchFailure.sessionStorageFailed }
        return data
    }
    public func save(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ResearchFailure.sessionStorageFailed }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ResearchFailure.sessionStorageFailed }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ResearchFailure.sessionStorageFailed
        }
    }
}

protocol CookieSessionExecuting: HTTPExecuting {
    func exportCookieData() throws -> Data
    func importCookieData(_ data: Data) throws
}

struct SavedResearchSession: Codable {
    let version: Int
    let id: String
    let supabaseUserID: String
    let cookies: Data
}

enum ResearchCookieCodec {
    static func encode(_ cookies: [HTTPCookie]) throws -> Data {
        let properties = try cookies.map { cookie -> [String: Any] in
            guard let source = cookie.properties else { throw ResearchFailure.sessionStorageFailed }
            return Dictionary(
                uniqueKeysWithValues: source.map { key, value in
                    (key.rawValue, (value as? URL).map { $0.absoluteString } as Any? ?? value)
                })
        }
        do {
            return try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
        } catch { throw ResearchFailure.sessionStorageFailed }
    }

    static func decode(_ data: Data) throws -> [HTTPCookie] {
        guard data.count <= 1_048_576,
            let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
            list.count <= 256
        else { throw ResearchFailure.sessionStorageFailed }
        return try list.map { values in
            let properties = Dictionary(uniqueKeysWithValues: values.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            guard let cookie = HTTPCookie(properties: properties),
                ["arena.ai", ".arena.ai"].contains(cookie.domain.lowercased())
            else { throw ResearchFailure.sessionStorageFailed }
            return cookie
        }
    }
}
