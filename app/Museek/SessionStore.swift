import Foundation
import Security

struct SessionStore: Sendable {
    private let service = "app.museek.session"
    private let account = "current"

    func load() throws -> AppSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError.unavailable }
        return try JSONDecoder().decode(AppSession.self, from: data)
    }

    func save(_ session: AppSession) throws {
        let data = try JSONEncoder().encode(session)
        let updates: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            updates.forEach { query[$0.key] = $0.value }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw StoreError.unavailable }
        } else if status != errSecSuccess { throw StoreError.unavailable }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.unavailable }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    enum StoreError: Error { case unavailable }
}
