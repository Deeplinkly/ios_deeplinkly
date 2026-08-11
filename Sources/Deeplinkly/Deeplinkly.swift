// Deeplinkly.swift
import Foundation

/// The Deeplinkly SDK.
///
/// Typical native integration:
///
/// ```swift
/// func application(
///     _ application: UIApplication,
///     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
/// ) -> Bool {
///     Deeplinkly.initialize()
///     Deeplinkly.setDeepLinkListener(router)
///     return true
/// }
/// ```
///
/// and, for every way a link can arrive:
///
/// ```swift
/// func application(
///     _ application: UIApplication,
///     continue userActivity: NSUserActivity,
///     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
/// ) -> Bool {
///     if let url = userActivity.webpageURL { Deeplinkly.handleLink(url) }
///     return false
/// }
/// ```
///
/// This is the SDK's entire public surface, alongside
/// `DeeplinklyDeepLinkListener` and `AttributionLevel`. Everything behind it is
/// internal on purpose: the Flutter bridge used to reach into 24 static entry
/// points across 16 types, and extracting that as-is would have made the SDK's
/// internals its API.
///
/// Mirrors Android's `Deeplinkly` object wherever the concept is shared. Two
/// asymmetries are deliberate and should not be "fixed": Android has
/// Activity/Intent entry points iOS cannot have, and iOS has a pasteboard
/// surface Android has no use for, because the Play Install Referrer covers
/// there what the clipboard has to cover here.
public enum Deeplinkly {

    /// `Info.plist` key naming the API key, matching Android's
    /// `com.deeplinkly.sdk.api_key` manifest meta-data.
    private static let infoPlistApiKey = "DeeplinklyApiKey"

    /// Guards `initialized`, `apiKey`, `isEnabled` and the pending link. Held
    /// only across the state read/write, never across the work that follows —
    /// `initialize` does its side effects after releasing it.
    private static let stateLock = NSLock()

    private static var initialized = false
    private static var storedApiKey = ""
    private static var enabled = false

    /// A link that arrived before the SDK was initialised.
    ///
    /// A Universal Link can reach a host app's delegate before it has called
    /// `initialize`, and on a cold start that is the launch the whole feature
    /// exists for. Held until initialisation flushes it.
    private static var pendingLink: URL?

    /// Guards the read-modify-write of the event sequence counter.
    private static let eventSeqLock = NSLock()

    // MARK: - Lifecycle

    /// Whether the SDK found an API key and is doing anything.
    ///
    /// False means `DeeplinklyApiKey` was missing or empty in `Info.plist`.
    /// Deep link delivery and every reporting call become no-ops; identity
    /// still works, exactly as on Android.
    public static var isEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return enabled
    }

    /// The SDK version, e.g. `1.9.0`.
    public static var version: String { SdkInfo.version }

    /// Starts the SDK, reading `DeeplinklyApiKey` from the app's `Info.plist`.
    ///
    /// Idempotent: the second and later calls return immediately, so a host
    /// that initialises from both its app delegate and a plugin registration
    /// cannot double-register anything. Android's `init` has the same latch and
    /// the same reason for it.
    public static func initialize() {
        let key = Bundle.main.object(forInfoDictionaryKey: infoPlistApiKey) as? String
        initialize(apiKey: key ?? "")
    }

    /// Starts the SDK with a key supplied directly.
    ///
    /// For hosts that hold the key somewhere other than `Info.plist` — a build
    /// configuration, a remote config, a keychain entry.
    public static func initialize(apiKey: String) {
        stateLock.lock()
        if initialized {
            stateLock.unlock()
            Logger.d("initialize() called again; ignoring")
            return
        }
        initialized = true
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        storedApiKey = key
        enabled = !key.isEmpty
        let flush = pendingLink
        pendingLink = nil
        stateLock.unlock()

        guard !key.isEmpty else {
            Logger.e("Missing API key in Info.plist (\(infoPlistApiKey))")
            return
        }

        // Resolve the WebView user agent before anything wants to send it.
        // WKWebView may only be constructed on the main thread, while every
        // collection path runs off it, so this is the one hop that makes the
        // agent a cached static signal instead of an async collection problem.
        DeviceProfile.primeUserAgent()

        // The only app-open signal on iOS. Without it a returning user who
        // never cold-starts the app is invisible — StartupEnrichment fires once
        // per process, and nothing else observed the foreground.
        AppOpenReporter.start(apiKey: key)

        StartupEnrichment.schedule(apiKey: key)

        // Pasteboard access has to happen on the main thread, and this is the
        // only deferred deep link channel iOS offers — see PasteboardHandler.
        DispatchQueue.main.async {
            PasteboardHandler.check(apiKey: key)
        }

        // retryAll blocks on a semaphore per item (15s timeout, up to 50
        // items). Running it inline froze the UI during plugin registration.
        DispatchQueue.global(qos: .utility).async {
            RetryQueue.retryAll(apiKey: key)
            DeepLinkHandler.drainPendingResolves(apiKey: key)
        }

        if let flush = flush {
            DeepLinkHandler.handle(url: flush, apiKey: key)
        }
    }

    /// Attaches the listener that receives resolved deep links, and drains
    /// anything that queued up before it arrived.
    ///
    /// Pass nil to detach.
    public static func setDeepLinkListener(_ listener: DeeplinklyDeepLinkListener?) {
        guard let listener = listener else {
            SdkRuntime.clearListener()
            return
        }
        SdkRuntime.setListener(listener)
    }

    /// Hands the SDK a link the app was opened with, or opened by.
    ///
    /// Call from every arrival path the app supports: `continue userActivity`,
    /// `open url`, and their `UIScene` equivalents. Android's
    /// `onActivityLaunch` / `onNewIntent` pair covers the same ground; iOS does
    /// not distinguish cold from warm here, because the callbacks already do.
    ///
    /// Calling it twice for one link is harmless — the resolve is idempotent,
    /// `AttributionStore.saveOnce` is write-once, and `DeepLinkDeliveryGuard`
    /// suppresses a duplicate arrival.
    public static func handleLink(_ url: URL) {
        stateLock.lock()
        let key = storedApiKey
        let ready = enabled
        if !ready { pendingLink = url }
        stateLock.unlock()

        guard ready else {
            Logger.d("Link arrived before initialize(); buffering")
            return
        }
        DeepLinkHandler.handle(url: url, apiKey: key)
    }

    /// Takes the link that arrived before initialisation, if one did and
    /// nothing has consumed it yet.
    ///
    /// The Flutter bridge answers `getInitialUniversalLink` from this. A native
    /// host does not need it: `initialize` flushes the same buffer through the
    /// normal delivery path.
    public static func takePendingLink() -> URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let link = pendingLink
        pendingLink = nil
        return link
    }

    /// Called when the app returns to the foreground.
    ///
    /// Optional — `AppOpenReporter` already observes
    /// `didBecomeActiveNotification` itself. Provided because the Flutter
    /// bridge has its own foreground signal from Dart, and both route through
    /// the same rate limit, so a double trigger is a no-op rather than a
    /// duplicate send.
    public static func onForeground() {
        stateLock.lock()
        let key = storedApiKey
        let ready = enabled
        stateLock.unlock()
        guard ready else { return }
        AppOpenReporter.report(apiKey: key)
    }

    /// Detaches the listener.
    ///
    /// Narrower than Android's `shutdown`, which also cancels a coroutine scope
    /// and stops a queue processor. iOS has neither: its work is dispatched
    /// per-task onto global queues, with nothing long-running to stop.
    public static func shutdown() {
        SdkRuntime.clearListener()
    }

    // MARK: - Identity

    /// First-touch attribution for this install. Empty until a link resolves.
    public static func getInstallAttribution() -> [String: Any] {
        AttributionStore.get()
    }

    /// The stable Deeplinkly id for this install.
    ///
    /// Works whether or not the SDK is enabled — it is generated locally and
    /// needs no API key.
    public static func getDeeplinklyId() -> String {
        DeviceIdManager.getOrCreate()
    }

    /// Sets your own user id, reported as `custom_user_id`.
    public static func setUserId(_ userId: String?) {
        stateLock.lock()
        let key = storedApiKey
        let ready = enabled
        stateLock.unlock()
        guard ready else { return }
        UserIdManager.updateCustomUserId(newId: userId, apiKey: key)
    }

    // MARK: - Events

    /// Logs a custom event.
    ///
    /// `completion` receives true only when the backend accepted it.
    /// Validation failures answer false without a network call; see
    /// `DeeplinklyEvent` for the rules.
    public static func logEvent(
        _ name: String,
        parameters: [String: Any] = [:],
        completion: ((Bool) -> Void)? = nil
    ) {
        stateLock.lock()
        let key = storedApiKey
        let ready = enabled
        stateLock.unlock()

        guard ready else {
            answer(false, to: completion)
            return
        }

        if let rejection = DeeplinklyEvent.validate(name: name, parameters: parameters) {
            Logger.w("Rejected event '\(name)': \(rejection.reason)")
            answer(false, to: completion)
            return
        }

        var params = parameters
        params["_dl_event_seq"] = String(nextEventSequence())
        // Milliseconds since the SDK initialised, not a raw systemUptime
        // reading. Same ordering power for events from a device with a wrong
        // wall clock, without also reporting how long the device has been
        // booted.
        params["_dl_client_elapsed_ms"] = String(SdkInfo.elapsedSinceInit())
        params["_dl_client_wall_epoch_ms"] = String(Int(Date().timeIntervalSince1970 * 1000))
        params["_dl_tz_offset_min"] = String(TimeZone.current.secondsFromGMT() / 60)
        // Joins this event to the device sample taken in the same visit. Free:
        // _dl_-prefixed keys are reserved and do not count against the caller's
        // 25-parameter budget.
        params["_dl_session_id"] = SessionManager.currentSessionId()

        NetworkUtils.logEvent(
            eventName: DeeplinklyEvent.normalizeName(name),
            parameters: params,
            apiKey: key
        ) { ok in
            answer(ok, to: completion)
        }
    }

    /// The next event sequence number, read and written under one lock.
    ///
    /// This was a plain `UserDefaults.integer(forKey:) + 1` in the bridge. Two
    /// `logEvent` calls landing together both read the same value and both
    /// wrote it back, so the counter that exists to order events handed out
    /// duplicates. `synchronize()` is the counterpart to Android's `commit()`:
    /// without it a process killed right after the call can reissue a number
    /// it already sent.
    private static func nextEventSequence() -> Int {
        eventSeqLock.lock()
        defer { eventSeqLock.unlock() }
        let next = UserDefaults.standard.integer(forKey: "dl_event_seq") + 1
        UserDefaults.standard.set(next, forKey: "dl_event_seq")
        UserDefaults.standard.synchronize()
        return next
    }

    // MARK: - Links

    /// Creates a Deeplinkly link from an already-flattened payload.
    ///
    /// The completion always receives a map — a failure is reported as
    /// `{success: false, error_code, error_message}` rather than nil, so a
    /// caller has one shape to read.
    public static func generateLink(
        payload: [String: Any],
        completion: @escaping ([String: Any]) -> Void
    ) {
        stateLock.lock()
        let key = storedApiKey
        let ready = enabled
        stateLock.unlock()

        guard ready else {
            answer(
                [
                    "success": false,
                    "error_code": "SDK_DISABLED",
                    "error_message": "Deeplinkly SDK disabled (missing API key).",
                ], to: completion)
            return
        }

        NetworkUtils.generateLink(payload: payload, apiKey: key) { response in
            answer(response, to: completion)
        }
    }

    // MARK: - Privacy

    /// Turns reporting off entirely.
    ///
    /// Deep links still resolve and still deliver; this restricts what is
    /// reported, not what works. Behaves as `AttributionLevel.none` and wins
    /// over any level set.
    public static func setTrackingEnabled(_ enabled: Bool) {
        TrackingPreferences.setTrackingDisabled(!enabled)
    }

    /// Whether reporting is currently on.
    public static func isTrackingEnabled() -> Bool {
        !TrackingPreferences.isTrackingDisabled()
    }

    /// Restricts which device signals are reported.
    @discardableResult
    public static func setAttributionLevel(_ level: AttributionLevel) -> Bool {
        AttributionLevel.set(level)
        return true
    }

    /// The level currently in force.
    public static func getAttributionLevel() -> AttributionLevel {
        AttributionLevel.current
    }

    // MARK: - Debug

    /// Turns on verbose console output under the `Deeplinkly` tag.
    public static func setDebugMode(_ enabled: Bool) {
        Logger.setDebugMode(enabled)
    }

    // MARK: - Pasteboard (iOS only)
    //
    // No Android counterpart, and none is wanted: the Play Install Referrer
    // covers there what the clipboard has to cover here. Android's bridge
    // answers these three with false.

    /// Turns the automatic pasteboard read on or off.
    ///
    /// - Parameter checkNow: when enabling, read immediately. Enabling at
    ///   runtime is inherently late — initialisation has already run — so
    ///   unless the caller opts out, read straight away rather than waiting for
    ///   a next launch the pasteboard may not survive to.
    public static func setCheckPasteboardOnInstall(_ enabled: Bool, checkNow: Bool = true) {
        stateLock.lock()
        let key = storedApiKey
        stateLock.unlock()
        PasteboardHandler.setCheckEnabled(enabled, apiKey: key, runCheckNow: checkNow)
    }

    /// Whether reading the pasteboard right now would make iOS show its paste
    /// banner. Reads no content and shows no banner itself.
    public static func willShowPasteboardBanner(completion: @escaping (Bool) -> Void) {
        PasteboardHandler.willShowBanner(completion: completion)
    }

    /// Reads the pasteboard now, if the read is enabled and has not run.
    public static func checkPasteboardNow() {
        stateLock.lock()
        let key = storedApiKey
        let ready = enabled
        stateLock.unlock()
        guard ready else { return }
        PasteboardHandler.check(apiKey: key)
    }

    /// Handles a paste the user made deliberately, through a system paste
    /// control.
    ///
    /// The banner-free deferred path: no "Pasted from…" prompt, because the
    /// user pasted on purpose.
    public static func handlePaste(
        itemProviders: [NSItemProvider],
        completion: @escaping (Bool) -> Void
    ) {
        stateLock.lock()
        let key = storedApiKey
        stateLock.unlock()
        PasteboardHandler.handle(
            itemProviders: itemProviders, apiKey: key, completion: completion)
    }

    // MARK: - Helpers

    /// Answers a caller on the main thread.
    ///
    /// Every completion above can be reached from a URLSession queue. Callers
    /// routinely touch UI in these, and the Flutter bridge must answer its
    /// `FlutterResult` on the platform thread, so the hop belongs here rather
    /// than in each of them.
    private static func answer<T>(_ value: T, to completion: ((T) -> Void)?) {
        guard let completion = completion else { return }
        if Thread.isMainThread {
            completion(value)
        } else {
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// Test seam: forgets that `initialize` ran.
    ///
    /// The counterpart to Android's `resetForTesting`, and needed for the same
    /// reason — this is process-global state that outlives any one test.
    internal static func resetForTesting() {
        stateLock.lock()
        initialized = false
        storedApiKey = ""
        enabled = false
        pendingLink = nil
        stateLock.unlock()
    }
}
