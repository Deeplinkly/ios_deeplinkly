import Foundation

enum Logger {
    private static let tag = "Deeplinkly"

    /// Off unless the host app calls `setDebugMode(true)`. Errors still print:
    /// an SDK that swallows its own failures silently is undebuggable.
    private static let lock = NSLock()
    private static var debugEnabled = false

    static func setDebugMode(_ enabled: Bool) {
        lock.lock()
        debugEnabled = enabled
        lock.unlock()
    }

    static var isDebugEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return debugEnabled
    }

    static func d(_ msg: String) {
        guard isDebugEnabled else { return }
        print("✅ [\(tag)] \(msg)")
    }

    static func w(_ msg: String) {
        guard isDebugEnabled else { return }
        print("⚠️ [\(tag)] \(msg)")
    }

    static func e(_ msg: String, _ error: Error? = nil) {
        if let error = error {
            print("❌ [\(tag)] \(msg) – \(error.localizedDescription)")
        } else {
            print("❌ [\(tag)] \(msg)")
        }
    }
}
