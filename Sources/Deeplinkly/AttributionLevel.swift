// AttributionLevel.swift
import Foundation

/// How much the SDK is allowed to report about a device.
///
/// A single on/off switch (`disableTracking`) is too blunt for consent flows
/// that need a middle ground: an app under GDPR may have consent to attribute
/// an install while having none to describe the hardware it happened on.
/// Mirrors the tiering Branch exposes as `BranchAttributionLevel`.
///
/// Ordering matters — each level is a strict subset of the one above it. Which
/// keys each level permits is not decided here: it lives in `SignalCatalogue`,
/// generated from `tool/signals.json` so this file, Android's
/// `AttributionLevel.kt` and the backend cannot disagree about what a given
/// consent choice means.
public enum AttributionLevel: String, CaseIterable {
    /// Everything the SDK collects. The default, and the pre-1.9.0 behaviour.
    case full

    /// Drops every signal classified `.full` — the high-entropy hardware
    /// signals that only exist to support probabilistic matching (screen
    /// geometry, core count, model). Keeps the coarse context a marketer
    /// actually reads: locale, timezone, OS, app version.
    case reduced

    /// Only signals classified `.minimal`: who the install is, which app build,
    /// and the link being reported on. Nothing describing the device.
    case minimal

    /// No enrichment is sent at all. Links still resolve and still deliver —
    /// this suppresses reporting, not functionality.
    case none

    private static let storageKey = "dl_attribution_level"
    private static let infoPlistKey = "DeeplinklyAttributionLevel"

    /// The level in force. `disableTracking` is absolute and collapses to
    /// `.none` regardless of what was set here.
    static var current: AttributionLevel {
        if TrackingPreferences.isTrackingDisabled() { return .none }
        if let stored = UserDefaults.standard.string(forKey: storageKey),
            let level = AttributionLevel(rawValue: stored)
        {
            return level
        }
        // Host apps that want to start restricted need to say so before any
        // code of theirs runs — the first enrichment can be sent during plugin
        // registration, long before Dart could call setAttributionLevel.
        if let configured = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
            let level = AttributionLevel(rawValue: configured.lowercased())
        {
            return level
        }
        return .full
    }

    static func set(_ level: AttributionLevel) {
        UserDefaults.standard.set(level.rawValue, forKey: storageKey)
        Logger.d("Attribution level set to \(level.rawValue)")
    }

    /// Whether any enrichment may leave the device.
    var allowsEnrichment: Bool { self != .none }

    /// Strips a collected payload down to what this level permits.
    ///
    /// Generic over the value type so it applies equally to the `[String: String]`
    /// that `DeviceProfile` produces and the `[String: String?]` that
    /// `EnrichmentSender` assembles on top of it.
    ///
    /// Every decision is delegated to `SignalCatalogue`, which is generated from
    /// `tool/signals.json` and shared with Android and the backend. The two
    /// platforms previously kept hand-written key sets that had already drifted
    /// — Kotlin listed eleven high-entropy keys against this file's five — so
    /// the same consent choice meant different things per platform.
    func filter<V>(_ payload: [String: V]) -> [String: V] {
        payload.filter { SignalCatalogue.allows($0.key, at: self) }
    }
}
