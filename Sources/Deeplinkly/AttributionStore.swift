// AttributionStore.swift
import Foundation

enum AttributionStore {
    private static let key = "initial_attribution"

    private static let lock = NSLock()
    private static var listeners: [UUID: ([String: Any]) -> Void] = [:]

    static func saveOnce(map: [String: String?]) {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: key) != nil { return }
        let filtered = map.compactMapValues { $0 }
        if let data = try? JSONSerialization.data(withJSONObject: filtered) {
            defaults.set(String(data: data, encoding: .utf8), forKey: key)
            notify(filtered)
        }
    }

    static func get() -> [String: Any] {
        guard let s = UserDefaults.standard.string(forKey: key),
            let data = s.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    // MARK: - Listeners

    /// Lets `StartupEnrichment` wait on attribution arriving instead of polling
    /// for it once a second. Returns a token for removal.
    @discardableResult
    static func addListener(_ listener: @escaping ([String: Any]) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        listeners[token] = listener
        lock.unlock()
        return token
    }

    static func removeListener(_ token: UUID) {
        lock.lock()
        listeners.removeValue(forKey: token)
        lock.unlock()
    }

    private static func notify(_ attribution: [String: Any]) {
        lock.lock()
        let current = Array(listeners.values)
        lock.unlock()
        for listener in current { listener(attribution) }
    }
}
