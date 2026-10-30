import Foundation
import Security

/// Secrets are isolated from the Codable connection metadata.
public enum NetworkCredentials {
    private static let service = "dev.farmac.network"
    public static func password(for id: UUID) throws -> String? {
        var query = key(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(status) }
        return value
    }
    public static func save(password: String, for id: UUID) throws {
        let data = Data(password.utf8), query = key(id)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    public static func remove(for id: UUID) throws {
        let result = SecItemDelete(key(id) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw failure(result) }
    }
    private static func key(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    private static func failure(_ status: OSStatus) -> NetworkError {
        .io("Связка ключей: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "код \(status)"))
    }
}
