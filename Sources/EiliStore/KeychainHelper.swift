import Foundation
import Security

/// 簡單的 Keychain 封裝
public enum KeychainHelper {
    private static let service = "com.paxstore.app"
    
    @discardableResult
    public static func save(_ data: Data, forKey key: String) -> Bool {
        // 先刪舊的
        delete(forKey: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    public static func load(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
    
    /// 只讀 Keychain 項目的元數據（創建時間等），不返回敏感內容
    /// 用於診斷 session 何時寫入，不洩露 session 本身
    public static func metadata(forKey key: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    /// session 的創建時間（診斷用，不讀取內容）
    public static func sessionCreationDate() -> Date? {
        guard let meta = metadata(forKey: "paxstore.auth.session"),
              let date = meta[kSecAttrCreationDate as String] as? Date else {
            return nil
        }
        return date
    }

    @discardableResult
    public static func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    // MARK: - 便利方法
    
    public static func saveString(_ string: String, forKey key: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return save(data, forKey: key)
    }
    
    public static func loadString(forKey key: String) -> String? {
        guard let data = load(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    public static func saveCodable<T: Codable>(_ value: T, forKey key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return save(data, forKey: key)
    }
    
    public static func loadCodable<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = load(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
