import Foundation
import Security

enum Keychain {
    /// Scopes our items so the account name alone is not the whole key.
    private static let service = "com.deeplinkly.sdk"

    /// The install id must survive a launch that happens before the user has
    /// unlocked the device (background fetch, push-triggered launch). The
    /// default protection class is `WhenUnlocked`, under which such a read
    /// fails and `DeviceIdManager` mints a *new* id — silently splitting one
    /// user's attribution across two identities.
    private static let accessible = kSecAttrAccessibleAfterFirstUnlock

    /// SwiftPM's unhosted iOS test runner has no Keychain entitlement. Package
    /// tests opt into this process-local store; app-hosted integration tests
    /// leave it nil and exercise Security.framework itself.
    private static let testingLock = NSLock()
    private static var testingStorage: [String: String]?

    static func useInMemoryStorageForTesting() {
        testingLock.lock()
        defer { testingLock.unlock() }
        if testingStorage == nil { testingStorage = [:] }
    }

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        testingLock.lock()
        if testingStorage != nil {
            testingStorage?[key] = value
            testingLock.unlock()
            return true
        }
        testingLock.unlock()

        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item
        SecItemDelete(baseQuery(for: key) as CFDictionary)

        // Add new item
        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = accessible

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        testingLock.lock()
        if let testingStorage = testingStorage {
            let value = testingStorage[key]
            testingLock.unlock()
            return value
        }
        testingLock.unlock()

        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            // Items written before kSecAttrService was introduced are keyed by
            // account alone. Find them, then migrate so the fallback is a
            // one-time cost rather than a permanent second lookup.
            var legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            legacyQuery[kSecAttrService as String] = nil
            status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data,
                let string = String(data: data, encoding: .utf8)
            {
                _ = set(string, for: key)
                return string
            }
            return nil
        }

        guard status == errSecSuccess,
            let data = result as? Data,
            let string = String(data: data, encoding: .utf8)
        else { return nil }

        return string
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        testingLock.lock()
        if testingStorage != nil {
            let existed = testingStorage?.removeValue(forKey: key) != nil
            testingLock.unlock()
            return existed
        }
        testingLock.unlock()

        let currentStatus = SecItemDelete(baseQuery(for: key) as CFDictionary)

        // Releases before kSecAttrService was introduced stored the device ID
        // under the account name alone. Delete that legacy item as well: a
        // privacy reset must work even when tracking was disabled before the
        // first read had a chance to migrate it.
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        let legacyStatus = SecItemDelete(legacyQuery as CFDictionary)
        return currentStatus == errSecSuccess || legacyStatus == errSecSuccess
    }
}
