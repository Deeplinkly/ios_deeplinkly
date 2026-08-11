// DeviceProfile.swift
import Foundation
import UIKit

#if canImport(WebKit)
    import WebKit
#endif

/// The part of the device description that does not change while the app is
/// installed: hardware, app build, install provenance.
///
/// Collected once and cached in `UserDefaults`. Deliberately **not** the
/// keychain, unlike `DeviceIdManager`: keychain items survive app deletion, so
/// a cached profile stored there would be resurrected onto a fresh install and
/// describe the previous one.
///
/// Anything that can change between two sends of the same install — the ATT
/// status, connection type, locale, the clock — is not here. It belongs in the
/// dynamic block, collected fresh at send time.
enum DeviceProfile {
    private static let profileKey = "dl_static_profile"
    private static let stampKey = "dl_static_profile_stamp"
    private static let installInstanceIdKey = "dl_install_instance_id"
    private static let firstAppVersionKey = "dl_first_app_version"
    private static let firstOpenAtKey = "dl_first_open_at"

    /// Suffix of the per-source dedupe latches `EnrichmentSender` writes.
    private static let enrichedLatchSuffix = "_enriched"

    private static let lock = NSLock()
    private static var cached: [String: String]?

    /// The cached profile, collecting it first if the cache is cold or stale.
    ///
    /// Single-flight under a plain lock: collection is synchronous, so there is
    /// no completion plumbing to add. The one signal that would have forced an
    /// async API — the WebView user agent — is resolved on the main thread by
    /// `primeUserAgent()` at plugin bootstrap, long before the first send.
    static func current() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cached { return cached }

        let stamp = currentStamp()
        let profile: [String: String]
        if let stored = readStored(stamp: stamp) {
            profile = stored
        } else {
            profile = collect(stamp: stamp)
        }
        cached = profile
        return profile
    }

    /// Drops the cache so the next `current()` re-collects.
    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: stampKey)
    }

    // MARK: - The stamp

    /// What the cached profile is keyed on. A change in any component means the
    /// cached values may be wrong, so the profile is collected again.
    ///
    /// `identifierForVendor` is the load-bearing component and must not be
    /// "simplified" away: iOS restores `UserDefaults` from an encrypted or
    /// iCloud backup onto a *different physical device*. Without it, a restored
    /// install would keep reporting the old phone's model, screen geometry and
    /// IDFV for the life of the install.
    ///
    /// `SignalCatalogue.version` matters for the opposite reason: a signal added
    /// in an SDK release must get collected on installs whose app version never
    /// changed.
    private static func currentStamp() -> String {
        let bundle = Bundle.main.infoDictionary
        let parts: [String] = [
            SdkInfo.version,
            String(SignalCatalogue.version),
            (bundle?["CFBundleShortVersionString"] as? String) ?? "",
            (bundle?["CFBundleVersion"] as? String) ?? "",
            UIDevice.current.systemVersion,
            systemBuildVersion() ?? "",
            UIDevice.current.identifierForVendor?.uuidString ?? "",
        ]
        return hash(parts.joined(separator: "|"))
    }

    /// FNV-1a, 64-bit. Not a security boundary — just a short stable key.
    private static func hash(_ value: String) -> String {
        var h: UInt64 = 14_695_981_039_346_656_037
        for byte in Array(value.utf8) {
            h ^= UInt64(byte)
            h = h &* 1_099_511_628_211
        }
        return String(format: "%016lx", h)
    }

    // MARK: - Storage

    private static func readStored(stamp: String) -> [String: String]? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: stampKey) == stamp,
            let stored = defaults.dictionary(forKey: profileKey) as? [String: String]
        else { return nil }
        return stored
    }

    private static func persist(_ profile: [String: String], stamp: String) {
        let defaults = UserDefaults.standard
        defaults.set(profile, forKey: profileKey)
        defaults.set(stamp, forKey: stampKey)
    }

    /// Clears the per-source dedupe latches so the next send actually goes out.
    ///
    /// `EnrichmentSender` latches `"<source>_enriched"` forever. For sources
    /// with no click identity — `app_start` above all — that meant an app
    /// upgrade never re-reported the new `app_version`: the latch was set on
    /// first launch of the first version and never cleared again. A changed
    /// stamp is exactly the moment that becomes wrong, so the two are tied
    /// together here rather than in the sender.
    private static func clearIdentitylessLatches() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasSuffix(enrichedLatchSuffix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Collection

    private static func collect(stamp: String) -> [String: String] {
        var out: [String: String] = [:]
        let device = UIDevice.current
        let bundle = Bundle.main.infoDictionary

        out["deeplinkly_device_id"] = DeviceIdManager.getOrCreate()
        out["install_instance_id"] = installInstanceId()
        out["platform"] = SdkInfo.platform
        out["sdk_version"] = SdkInfo.version
        out["static_profile_version"] = stamp

        // --- app build ---
        let appVersion = bundle?["CFBundleShortVersionString"] as? String
        out["app_id"] = Bundle.main.bundleIdentifier
        out["app_version"] = appVersion
        out["app_build_number"] = bundle?["CFBundleVersion"] as? String
        out["installed_at"] = installedAt()
        out["environment"] = environment()

        // First-seen values, latched. `installed_at` is when the app's
        // container was created; `first_open_at` is the first time our code
        // ran, which is what an install cohort actually means.
        out["first_app_version"] = latch(firstAppVersionKey, appVersion)
        out["first_open_at"] = latch(firstOpenAtKey, iso8601(Date()))

        // --- os ---
        out["os_version"] = device.systemVersion
        out["os_build_id"] = systemBuildVersion()

        // --- hardware ---
        out["manufacturer"] = "Apple"
        out["brand"] = "Apple"
        // The hardware identifier ("iPhone15,2"), not UIDevice.model, which
        // returns the family string "iPhone" for every iPhone ever made and is
        // what this field used to carry.
        out["device_model"] = hardwareIdentifier()
        out["device_class"] = deviceClass()
        out["cpu_type"] = cpuType()
        out["hardware_concurrency"] = String(ProcessInfo.processInfo.processorCount)
        out["is_emulator"] = String(isSimulator())

        let screen = UIScreen.main
        // nativeBounds is in physical pixels and is orientation-independent;
        // bounds × scale is neither.
        let native = screen.nativeBounds
        out["screen_width"] = String(Int(native.width))
        out["screen_height"] = String(Int(native.height))
        out["pixel_ratio"] = String(format: "%.2f", screen.scale)
        out["screen_dpi"] = String(Int((screen.scale * 163).rounded()))

        // --- identifiers ---
        let idfv = device.identifierForVendor?.uuidString
        out["idfv"] = idfv
        out["is_hardware_id_real"] = String(idfv != nil)

        out["webview_user_agent"] = cachedUserAgent()

        persist(out, stamp: stamp)
        clearIdentitylessLatches()
        Logger.d("Collected static device profile (\(out.count) signals, stamp \(stamp))")
        return out
    }

    // MARK: - Individual signals

    /// The hardware identifier, e.g. `iPhone15,2`.
    ///
    /// `hw.machine` rather than `uname()`: reading `utsname.machine` needs an
    /// unsafe pointer into a tuple field, which Swift's exclusivity checking
    /// rejects outright. On the simulator `hw.machine` reports the host Mac's
    /// architecture, so the simulated device is read from the environment
    /// instead — otherwise every simulator install would look like an `arm64`
    /// device model.
    private static func hardwareIdentifier() -> String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        return sysctlString("hw.machine")
    }

    /// The OS build, e.g. `22F76`. Pins the exact point release.
    private static func systemBuildVersion() -> String? {
        sysctlString("kern.osversion")
    }

    /// The Mach CPU type as an integer, matching what Branch reports.
    private static func cpuType() -> String? {
        var type = cpu_type_t()
        var size = MemoryLayout<cpu_type_t>.size
        guard sysctlbyname("hw.cputype", &type, &size, nil, 0) == 0 else { return nil }
        return String(type)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func deviceClass() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "tablet"
        case .tv: return "tv"
        case .carPlay: return "car"
        case .mac: return "desktop"
        default: return "phone"
        }
    }

    private static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        #endif
    }

    /// When the app's container was created — the closest iOS gets to Android's
    /// `firstInstallTime`.
    ///
    /// Reads a file creation date, which is a required-reason API: the podspec's
    /// `PrivacyInfo.xcprivacy` declares `C617.1` (files created by the app) to
    /// cover it.
    private static func installedAt() -> String? {
        guard
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let created = attributes[.creationDate] as? Date
        else { return nil }
        return iso8601(created)
    }

    private static func environment() -> String {
        // An App Clip's bundle carries an AppClip entry in its Info.plist.
        if Bundle.main.infoDictionary?["NSAppClip"] != nil { return "APP_CLIP" }
        return "FULL_APP"
    }

    // MARK: - WebView user agent

    private static let userAgentKey = "dl_webview_user_agent"

    /// Resolves the WebView user agent once and stores it.
    ///
    /// Must run on the main thread: `WKWebView` may not be constructed off it.
    /// Called from the plugin's `bootstrap()` so the value is already in
    /// `UserDefaults` by the time any enrichment is assembled — which is why
    /// this is a static signal rather than a dynamic one. It changes only with
    /// the WebView or OS version, and both are in the stamp.
    static func primeUserAgent() {
        #if canImport(WebKit)
            guard cachedUserAgent() == nil else { return }
            DispatchQueue.main.async {
                let webView = WKWebView(frame: .zero)
                webView.evaluateJavaScript("navigator.userAgent") { result, _ in
                    guard let agent = result as? String, !agent.isEmpty else { return }
                    UserDefaults.standard.set(agent, forKey: userAgentKey)
                    // The profile may already have been collected without it;
                    // drop the cache so the next send picks it up.
                    invalidate()
                    // Keep a strong reference alive until the callback runs.
                    _ = webView
                }
            }
        #endif
    }

    private static func cachedUserAgent() -> String? {
        UserDefaults.standard.string(forKey: userAgentKey)
    }

    // MARK: - Latches

    /// Stores `value` under `key` the first time only, returning what is stored.
    private static func latch(_ key: String, _ value: String?) -> String? {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        guard let value = value else { return nil }
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static func installInstanceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: installInstanceIdKey) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: installInstanceIdKey)
        return fresh
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
