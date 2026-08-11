// SessionManager.swift
import Foundation

/// Groups everything one visit produces under a single id.
///
/// A session is a 30-minute inactivity window: any open or event inside it
/// extends it, and the first one past it starts a new session. That is what
/// makes an event joinable to the device sample taken alongside it — without
/// which a `DeviceSignalSample` and an `SdkEvent` from the same visit have
/// nothing but a timestamp in common.
///
/// Persisted rather than held in memory, so a session survives the process
/// being killed and relaunched inside the window. Kept in lockstep with
/// Android's `SessionManager.kt`.
enum SessionManager {
    private static let sessionIdKey = "dl_session_id"
    private static let sessionLastAtKey = "dl_session_last_at"

    /// How long a session survives with no activity.
    static let sessionWindow: TimeInterval = 30 * 60

    private static let lock = NSLock()

    /// The current session id, starting a new one if the window has lapsed.
    ///
    /// Touches the activity timestamp, so simply asking extends the session —
    /// which is what "any open or event extends it" means in practice.
    static func currentSessionId(now: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }

        let defaults = UserDefaults.standard
        let lastAt = defaults.double(forKey: sessionLastAtKey)
        let existing = defaults.string(forKey: sessionIdKey)

        let id: String
        if let existing = existing, now.timeIntervalSince1970 - lastAt <= sessionWindow {
            id = existing
        } else {
            id = UUID().uuidString
            Logger.d("Started session \(id)")
        }

        defaults.set(id, forKey: sessionIdKey)
        defaults.set(now.timeIntervalSince1970, forKey: sessionLastAtKey)
        return id
    }
}
