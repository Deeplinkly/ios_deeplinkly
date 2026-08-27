// EnrichmentSender.swift
import Foundation

/// The one place an enrichment payload is assembled.
///
/// Callers pass only the link identity — which click, which campaign, which
/// source. The device description is added here, at send time, from the cached
/// static profile plus a fresh dynamic sample. Nothing device-shaped is carried
/// in from a caller or a queue, so a payload replayed from storage days later
/// still describes the device as it is now rather than as it was.
enum EnrichmentSender {
    /// Sources that describe a lifecycle moment rather than a link.
    private static let lifecycleSources: Set<String> = ["app_start", "app_open"]

    /// The source `setUserData`/`clearUserData` report under.
    static let userDataSource = "user_data"

    /// - Parameter attributionData: link identity only — click_id/code, source,
    ///   the UTMs, the ad-click ids. Device signals passed here are overwritten.
    /// - Parameter force: send even without attribution evidence. Used by
    ///   `StartupEnrichment` when its wait times out — an install with no link
    ///   behind it is still an install.
    static func sendOnce(
        attributionData: [String: String?],
        source: String,
        apiKey: String,
        force: Bool = false
    ) {
        guard !TrackingPreferences.isTrackingDisabled() else { return }

        let level = AttributionLevel.current
        guard level.allowsEnrichment else {
            Logger.d("Attribution level is none; not sending enrichment.")
            return
        }

        let staticProfile = DeviceProfile.current()
        var payload: [String: String?] = [:]
        for (key, value) in staticProfile { payload[key] = value }
        for (key, value) in DynamicSignals.collect(staticProfile: staticProfile) {
            payload[key] = value
        }
        payload["custom_user_id"] = Prefs.customUserId()
        // What the host app told us about the person, if anything. Read here
        // rather than passed in for the same reason the device profile is: a
        // payload replayed out of the retry queue days later should carry what
        // we know now, and a caller has no business supplying someone else's
        // details on one particular enrichment.
        //
        // Empty values are meaningful here and must survive — see
        // UserDataStore.clear.
        for (key, value) in UserDataStore.get() { payload[key] = value }
        for (key, value) in attributionData { payload[key] = value }

        // Reported so the backend can tell a thin payload from a missing one.
        // Both must survive MINIMAL — explaining why a payload is small is the
        // one thing that stays useful at every level.
        payload["collected_at"] = iso8601(Date())
        payload["attribution_level"] = level.rawValue

        // Filter before deduping so the key describes what actually goes out.
        let data = level.filter(payload)

        // The latch used to be keyed on source alone and never cleared, which
        // made every source once-per-install *forever*: the second and every
        // later deep link never enriched, and setUserId (source
        // "custom_user_id") only ever linked the first login on the device.
        // Keying on what is being reported lets a genuinely new event through
        // while still collapsing duplicates.
        //
        // Lifecycle sources are exempt: they are rate-limited by their own
        // caller, and a latch here would drop a fresh dynamic sample on the
        // floor rather than merely collapsing a duplicate.
        let isLifecycle = lifecycleSources.contains(source)
        let key = dedupeKey(for: data, source: source)
        if !isLifecycle && Prefs.bool(for: key) { return }

        // Only send if we have attribution hints. "code" belongs here too —
        // Android counts it, and a code-only deferred link was silently dropped.
        let keys = [
            "click_id", "code", "utm_source", "utm_medium", "utm_campaign",
            "gclid", "fbclid", "ttclid", "gbraid", "wbraid",
        ]
        let hasAttr = keys.contains { (data[$0] ?? nil)?.isEmpty == false }
        guard hasAttr || force || isLifecycle else {
            Logger.d("Skipping enrichment: no attribution")
            return
        }

        Logger.d("Sending enrichment for \(source) at level \(level.rawValue)")

        // Latch only once the payload is actually delivered. Setting it up
        // front marked a permanently failing enrichment as sent.
        NetworkUtils.sendEnrichment(data, apiKey: apiKey) { delivered in
            if delivered && !isLifecycle { Prefs.set(true, for: key) }
        }
    }

    /// Identity of this enrichment: the source plus whatever attribution it
    /// carries. Two calls that would report the same thing collapse to one.
    static func dedupeKey(for data: [String: String?], source: String) -> String {
        let identityKeys = ["click_id", "code", "custom_user_id"]
        let identity =
            identityKeys
            .compactMap { key -> String? in
                guard let value = data[key] ?? nil, !value.isEmpty else { return nil }
                return "\(key)=\(value)"
            }
            .joined(separator: "&")
        // Not hashValue: Swift seeds String hashing per process, so the key
        // would differ on every launch and dedupe nothing.
        let base =
            identity.isEmpty
            ? "\(source)_enriched"
            : "\(source)_enriched_\(identity)"

        // For this one source, the user data *is* what is being reported, so it
        // has to be part of what makes two reports different. Without it, a
        // second setUserData call under the same custom_user_id — adding an
        // address to an email already sent, the common case — produces the same
        // key as the first and is latched away, never reaching us.
        //
        // A digest rather than the values, because this string becomes the name
        // of a UserDefaults key: writing someone's email address into one would
        // put it somewhere neither clearUserData nor the tombstone can reach,
        // and outside PrivacyData's inventory besides.
        guard source == userDataSource else { return base }
        let fingerprint =
            DeeplinklyUserData.keys
            .sorted()
            .compactMap { key -> String? in
                guard let value = data[key] ?? nil else { return nil }
                return "\(key)=\(value)"
            }
            .joined(separator: "&")
        return fingerprint.isEmpty ? base : "\(base)_\(stableDigest(fingerprint))"
    }

    /// FNV-1a, 64-bit, rendered hex.
    ///
    /// Written out rather than reached for because the two things to hand are
    /// both wrong here: `hashValue` is seeded per process and would dedupe
    /// nothing across launches, and CryptoKit is a heavier dependency than a
    /// dedupe key warrants. What matters is that it is stable across launches
    /// and identical to the Kotlin twin, and it is both.
    static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in Array(value.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
