import Foundation
import XCTest

@testable import Deeplinkly

/// Shared fixtures for the SDK unit tests.
///
/// Every unit under test is an `enum` with `static` members reading
/// `UserDefaults.standard` directly, so state leaks between test cases unless
/// it is cleared deliberately. `DeeplinklyTestSupport.reset()` is called from
/// `setUp` in every suite below.
///
/// Clearing is by explicit key rather than `removePersistentDomain`, which
/// would also wipe the host app's own defaults and anything Flutter caches
/// there. Adding a persisted key to the SDK means adding it here — otherwise
/// the first test that writes it silently poisons every test after it.
enum DeeplinklyTestSupport {
    /// Every `UserDefaults` key the SDK persists.
    ///
    /// Grouped by owner so a new key lands next to its siblings. Kept in the
    /// same order the files declare them.
    static let persistedKeys: [String] = [
        // DeepLinkQueue
        "dl_pending_resolve",
        // RetryQueue (canonical key followed by the pre-migration iOS key)
        "dl_pending_retries", "sdk_retry_queue",
        // AttributionLevel
        "dl_attribution_level",
        // TrackingPreferences
        "tracking_disabled",
        // Prefs
        "custom_user_id",
        // AttributionStore
        "initial_attribution",
        // SessionManager
        "dl_session_id", "dl_session_last_at",
        // DeviceProfile
        "dl_static_profile", "dl_static_profile_stamp", "dl_install_instance_id",
        "dl_first_app_version", "dl_first_open_at", "dl_webview_user_agent",
        // AppOpenReporter
        "dl_last_open_ping_at",
        // Deeplinkly (the facade owns the event sequence counter; it used to
        // be written inline by the plugin, which is why it was missing here)
        "dl_event_seq",
        // PasteboardHandler
        "deeplinkly_pasteboard_checked", "deeplinkly_check_pasteboard_on_install",
    ]

    /// Suffix of the per-source dedupe latches `EnrichmentSender` writes. The
    /// key is built at runtime from the source and the attribution identity, so
    /// it cannot be listed literally.
    static let enrichedLatchSuffix = "_enriched"

    static func reset() {
        Keychain.useInMemoryStorageForTesting()
        let defaults = UserDefaults.standard
        for key in persistedKeys { defaults.removeObject(forKey: key) }
        for key in defaults.dictionaryRepresentation().keys
        where key.contains(enrichedLatchSuffix) {
            defaults.removeObject(forKey: key)
        }

        // Static caches that outlive UserDefaults clearing.
        DeviceProfile.invalidate()
        SdkRuntime.clearListener()
        DeepLinkDeliveryGuard.reset()
        Deeplinkly.resetForTesting()
        LinkDomains.configuredDomainsOverride = [configuredDomain]
    }

    /// The link domain injected into `LinkDomains` for package tests.
    static let configuredDomain = "example.deeplinkly.com"
}

/// Records the deep links handed to it, standing in for whatever is listening.
///
/// Since the delivery funnel took a listener protocol instead of a
/// `FlutterMethodChannel`, testing it needs nothing from Flutter at all — this
/// is the whole substitute.
final class RecordingDeepLinkListener: DeeplinklyDeepLinkListener {
    private(set) var received: [[String: Any]] = []
    private(set) var receivedOnMainThread: [Bool] = []

    /// Runs inside `onDeepLink`, before `onDelivered` — lets a test observe the
    /// ordering between the two.
    var onReceive: (() -> Void)?

    var count: Int { received.count }
    var clickIds: [String?] { received.map { $0["click_id"] as? String } }

    func reset() {
        received = []
        receivedOnMainThread = []
    }

    func onDeepLink(_ payload: [String: Any]) {
        received.append(payload)
        receivedOnMainThread.append(Thread.isMainThread)
        onReceive?()
    }
}
