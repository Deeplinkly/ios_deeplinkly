// AppOpenReporter.swift
import Foundation
import UIKit

/// Reports a device sample when the app comes to the foreground.
///
/// iOS had no app-open hook at all before this: `onLifecycleChange` only set
/// the Flutter-ready flag, and `StartupEnrichment` fires once per process. A
/// returning user who never cold-started the app was invisible.
///
/// Rate-limited hard. `TenantUser` is rewritten on every open and is documented
/// as the hottest write path in the product; an unthrottled ping would multiply
/// that by the number of foreground transitions per session.
enum AppOpenReporter {
    private static let lastPingKey = "dl_last_open_ping_at"

    /// Matches the session window: at most one ping per session.
    private static let minPingInterval = SessionManager.sessionWindow

    static let source = "app_open"

    private static var observer: NSObjectProtocol?

    /// Idempotent — the plugin can be registered more than once per process.
    static func start(apiKey: String) {
        guard observer == nil, !apiKey.isEmpty else { return }

        // `UIApplication.didBecomeActiveNotification`, not
        // `UIScene.didActivateNotification`. The plugin already handles both
        // the app-delegate and the scene link callbacks, so it must work in
        // both worlds — and `didBecomeActive` is posted by UIApplication in
        // scene-based apps too, whereas the scene notification fires once per
        // scene and would double-fire on iPad multi-window.
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            report(apiKey: apiKey)
        }
        Logger.d("AppOpenReporter started")
    }

    /// Reports an open, unless one was already reported inside the window.
    ///
    /// The launch activation usually arrives while `StartupEnrichment` is also
    /// in flight. The rate limit is what makes that harmless rather than lucky.
    static func report(apiKey: String, now: Date = Date()) {
        guard !apiKey.isEmpty else { return }
        guard !TrackingPreferences.isTrackingDisabled() else { return }
        guard shouldPing(now: now) else { return }

        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastPingKey)

        // Off the main thread: assembling the payload touches the profile cache
        // and the dynamic collectors, and this runs inside a foreground
        // notification.
        DispatchQueue.global(qos: .utility).async {
            // No attribution: an open is a lifecycle moment, not a link.
            // EnrichmentSender lets lifecycle sources through its attribution
            // gate for exactly this reason.
            EnrichmentSender.sendOnce(
                attributionData: [:], source: source, apiKey: apiKey)
        }
    }

    static func shouldPing(now: Date = Date()) -> Bool {
        let last = UserDefaults.standard.double(forKey: lastPingKey)
        // 0 means "never pinged", not "pinged at the epoch". Comparing it as a
        // timestamp happens to work against a real wall clock only because that
        // number is large; say what is meant instead.
        if last == 0 { return true }
        return now.timeIntervalSince1970 - last >= minPingInterval
    }
}
