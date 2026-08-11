// DeviceIdManager.swift
import Foundation

enum DeviceIdManager {
    private static let key = "deeplinkly_device_id"

    static func getOrCreate() -> String {
        // 1️⃣ Try existing value from Keychain
        if let existing = Keychain.get(key) {
            return existing
        }

        // 2️⃣ Generate new UUID string
        let fresh = UUID().uuidString

        // 3️⃣ Persist in Keychain for future launches
        _ = Keychain.set(fresh, for: key)

        return fresh
    }
}
