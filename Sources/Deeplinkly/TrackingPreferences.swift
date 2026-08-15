// TrackingPreferences.swift
import Foundation
enum TrackingPreferences {
    private static let key = "tracking_disabled"
    static func isTrackingDisabled() -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func setTrackingDisabled(_ disabled: Bool) {
        UserDefaults.standard.set(disabled, forKey: key)
        // Make the opt-out visible before purging. An in-flight request can
        // fail on another queue while this runs; RetryQueue.enqueue checks the
        // persisted flag and must not recreate what we just deleted.
        UserDefaults.standard.synchronize()
        if disabled { RetryQueue.clear() }
    }
}
