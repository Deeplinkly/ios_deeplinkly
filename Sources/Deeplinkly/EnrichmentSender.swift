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
            "gclid", "fbclid", "ttclid",
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
    private static func dedupeKey(for data: [String: String?], source: String) -> String {
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
        return identity.isEmpty
            ? "\(source)_enriched"
            : "\(source)_enriched_\(identity)"
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
