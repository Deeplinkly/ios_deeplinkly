import Foundation

/// Owns the field-level deletion contract for Deeplinkly's local data.
enum PrivacyData {
    /// Every literal UserDefaults key written by the SDK. Dynamic enrichment
    /// dedupe keys are removed separately by suffix.
    static let persistedKeys: [String] = [
        "dl_pending_resolve",
        // RetryQueue moved to the Keychain on 28 August 2026 and is removed by
        // RetryQueue.clear() in reset() below. Both keys stay listed so a
        // device still carrying the plist copy — one written by an older build
        // and not yet migrated — is cleaned by a reset regardless.
        "dl_pending_retries", "sdk_retry_queue",
        "dl_attribution_level",
        PIIHashing.storageKey,
        "custom_user_id",
        // The person's own email and address moved to the Keychain on
        // 28 August 2026 and are removed by UserDataStore.purge() in reset()
        // below — a UserDefaults sweep no longer reaches them. The key stays on
        // this list so a device carrying a pre-release build, which wrote the
        // blob here, is still cleaned by a reset even if nothing ever read it
        // and triggered the migration.
        UserDataStore.storageKey,
        "initial_attribution",
        "dl_session_id", "dl_session_last_at",
        "dl_static_profile", "dl_static_profile_stamp", "dl_install_instance_id",
        "dl_first_app_version", "dl_first_open_at", "dl_webview_user_agent",
        "dl_last_open_ping_at",
        "dl_event_seq",
        // The consent record and the push token. Both are listed because
        // resetPrivacyData is a *local wipe* and must leave nothing behind.
        // Note that this is a different question from whether either survives a
        // backup restore, where they deliberately differ: consent is a decision
        // and travels, a push token addresses one handset and must not. See
        // ConsentStore and PushTokenStore.
        ConsentStore.storageKey,
        PushTokenStore.tokenKey, PushTokenStore.providerKey, PushTokenStore.installKey,
        "deeplinkly_pasteboard_checked", "deeplinkly_check_pasteboard_on_install",
    ]

    private static let enrichmentLatchPrefixes = [
        "deep_link_enriched",
        "consent_enriched",
        "push_token_enriched",
        "clipboard_enriched",
        "paste_control_enriched",
        "custom_user_id_enriched",
        "user_data_enriched",
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

        // Keychain-backed, so the UserDefaults sweep below cannot reach it.
        // Purge rather than clear: reset is a local wipe, and a tombstone is
        // owed to the service only when the caller asked for an erasure.
        UserDataStore.purge()

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
