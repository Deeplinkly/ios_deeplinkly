import Foundation

/// Owns the field-level deletion contract for Deeplinkly's local data.
enum PrivacyData {
    /// Every literal UserDefaults key written by the SDK. Dynamic enrichment
    /// dedupe keys are removed separately by suffix.
    static let persistedKeys: [String] = [
        "dl_pending_resolve",
        "dl_pending_retries", "sdk_retry_queue",
        "dl_attribution_level",
        "custom_user_id",
        "initial_attribution",
        "dl_session_id", "dl_session_last_at",
        "dl_static_profile", "dl_static_profile_stamp", "dl_install_instance_id",
        "dl_first_app_version", "dl_first_open_at", "dl_webview_user_agent",
        "dl_last_open_ping_at",
        "dl_event_seq",
        "deeplinkly_pasteboard_checked", "deeplinkly_check_pasteboard_on_install",
    ]

    private static let enrichmentLatchPrefixes = [
        "deep_link_enriched",
        "clipboard_enriched",
        "paste_control_enriched",
        "custom_user_id_enriched",
    ]

    private static func isEnrichmentLatch(_ key: String) -> Bool {
        enrichmentLatchPrefixes.contains { prefix in
            key == prefix || key.hasPrefix("\(prefix)_")
        }
    }

    static func reset() {
        // Persist opt-out first so in-flight failures cannot recreate retry
        // payloads while the remaining stores are being removed.
        TrackingPreferences.setTrackingDisabled(true)
        RetryQueue.clear()
        DeepLinkQueue.clear()
        SdkRuntime.clearPending()
        DeepLinkDeliveryGuard.reset()
        DeviceProfile.invalidate()
        _ = DeviceIdManager.reset()

        let defaults = UserDefaults.standard
        for key in persistedKeys { defaults.removeObject(forKey: key) }
        for key in defaults.dictionaryRepresentation().keys
        where isEnrichmentLatch(key) {
            defaults.removeObject(forKey: key)
        }

        // Deliberately retained; reset is deletion plus opt-out, never an
        // implicit return to the default Full reporting level.
        defaults.set(true, forKey: "tracking_disabled")
        defaults.synchronize()
    }
}
