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

    /// The SDK version, e.g. `1.0.0`.
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

        // Apple sends no SKAdNetwork postback unless the advertised app
        // registers, so without this the endpoint an app points
        // NSAdvertisingAttributionReportEndpoint at receives nothing at all.
        // See SkanRegistration for why the plist key alone is not enough.
        SkanRegistration.register()

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
    /// For adapter layers that resolve a cold-start URL themselves. Most hosts,
    /// native and Flutter alike, should not call it: `initialize` flushes the
    /// same buffer through the normal delivery path, and `SdkRuntime` holds the
    /// result until a listener attaches — so the link arrives through
    /// `setDeepLinkListener` either way.
    ///
    /// It drains the buffer, and `initialize` drains the same one, so exactly
    /// one of the two delivers a given link. Calling this *before* `initialize`
    /// therefore takes the link out of the normal path rather than duplicating
    /// it, and whatever calls it owns delivery from that point. The Flutter
    /// plugin used to expose this as `getInitialUniversalLink` and no Dart code
    /// ever called it; the channel case was removed on 28 August 2026 rather
    /// than left as a second consumer nobody was using.
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

    /// Records what you know about the person using your app.
    ///
    /// These are the fields a conversion is matched on once it is forwarded to
    /// Meta's Conversions API or Google's enhanced conversions, and this is the
    /// platform where that matters most: with App Tracking Transparency denied
    /// there is no IDFA, so a hashed email is the only match key left. Supplying
    /// one here is the difference between a purchase attributed to the campaign
    /// that produced it and one that is not.
    ///
    /// Values are sent as you supply them and hashed only at forwarding time;
    /// see `DeeplinklyUserData` for why on-device hashing would be security
    /// theatre rather than a safeguard. Supply only what your own privacy policy
    /// and consent flow allow — the SDK cannot know what you told your users.
    ///
    /// ## Merging
    ///
    /// Each call merges: a field left nil is left as it was, so you can call
    /// this at sign-up with an email and again at checkout with an address. That
    /// means a single field cannot be cleared by passing nil for it —
    /// ``clearUserData()`` erases all of them, and ``setUserId(_:)`` with nil
    /// clears just the id.
    ///
    /// - Parameters:
    ///   - userId: your own identifier for this person. Delegates to
    ///     ``setUserId(_:)``, so it shares that value rather than storing a
    ///     second copy.
    ///   - dateOfBirth: `YYYY-MM-DD`.
    ///   - gender: `"m"` or `"f"` — the only two values Meta's `ge` accepts.
    ///     Anything else is refused rather than coerced.
    ///   - country: ISO-3166-1 alpha-2, e.g. `"US"`.
    /// - Returns: false if any field was malformed, in which case **nothing**
    ///   was stored. All or nothing, so a rejected call never leaves you
    ///   guessing which of the values took.
    @discardableResult
    public static func setUserData(
        userId: String? = nil,
        email: String? = nil,
        phoneNumber: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        dateOfBirth: String? = nil,
        gender: String? = nil,
        street: String? = nil,
        city: String? = nil,
        state: String? = nil,
        zip: String? = nil,
        country: String? = nil,
        customData: [String: String?]? = nil
    ) -> Bool {
        stateLock.lock()
        let key = storedApiKey
        let ready = enabled
        stateLock.unlock()
        guard ready else { return false }

        // Encoded before the rest so a bad dictionary rejects the whole call,
        // which is the same all-or-nothing contract the twelve typed fields
        // have.
        let (encodedCustom, customRejection) =
            DeeplinklyUserData.encodeCustomData(customData)
        if let customRejection {
            Logger.w("Rejected setUserData: \(customRejection.reason)")
            return false
        }

        let result = DeeplinklyUserData.normalizeAll([
            DeeplinklyUserData.keyEmail: email,
            DeeplinklyUserData.keyPhone: phoneNumber,
            DeeplinklyUserData.keyFirstName: firstName,
            DeeplinklyUserData.keyLastName: lastName,
            DeeplinklyUserData.keyDateOfBirth: dateOfBirth,
            DeeplinklyUserData.keyGender: gender,
            DeeplinklyUserData.keyStreet: street,
            DeeplinklyUserData.keyCity: city,
            DeeplinklyUserData.keyState: state,
            DeeplinklyUserData.keyZip: zip,
            DeeplinklyUserData.keyCountry: country,
            DeeplinklyUserData.keyCustomData: encodedCustom,
        ])
        if let rejection = result.rejection {
            Logger.w("Rejected setUserData: \(rejection.reason)")
            return false
        }
        let fields = result.fields ?? [:]

        // The id first, and through the same manager setUserId uses, so there
        // is exactly one place custom_user_id is stored no matter which of the
        // two public entry points wrote it.
        if let trimmed = userId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        {
            UserIdManager.updateCustomUserId(newId: trimmed, apiKey: key)
        }

        guard !fields.isEmpty else { return true }
        UserDataStore.merge(fields)

        // force: knowing who someone is has nothing to do with whether a link
        // brought them here, so this must not be gated on attribution evidence
        // — an organic install would otherwise never report it.
        EnrichmentSender.sendOnce(
            attributionData: [:],
            source: EnrichmentSender.userDataSource,
            apiKey: key,
            force: true
        )
        return true
    }

    /// Forgets everything ``setUserData(userId:email:phoneNumber:firstName:lastName:dateOfBirth:gender:street:city:state:zip:country:)``
    /// and ``setUserId(_:)`` recorded, here and on our servers.
    ///
    /// Call it on sign-out, or when someone withdraws consent. Unlike letting
    /// the values simply stop being sent, this actively erases them: the next
    /// enrichment carries each previously-set field as an empty value, which the
    /// service reads as "null this column" rather than "not reported".
    ///
    /// The erasure is re-sent until it is delivered, so calling this on a device
    /// that is offline still takes effect once it is not.
    public static func clearUserData() {
        stateLock.lock()
        let key = storedApiKey
        let ready = enabled
        stateLock.unlock()
        guard ready else { return }

        UserIdManager.updateCustomUserId(newId: nil, apiKey: key)
        UserDataStore.clear()
        EnrichmentSender.sendOnce(
            attributionData: [:],
            source: EnrichmentSender.userDataSource,
            apiKey: key,
            force: true
        )
    }

    // MARK: - Events

    /// Logs a custom event.
    ///
    /// `completion` receives true only when the service accepted it.
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
        // One id per call, and the same id on every replay of it: the retry
        // queue stores the payload built here, so an event that was delivered
        // but whose response was lost comes back carrying the id the service
        // already has and is refused as the duplicate it is. Meta CAPI's
        // `event_id` wants the same value.
        params["_dl_event_id"] = UUID().uuidString
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

    /// Logs a purchase.
    ///
    /// A thin, typed wrapper over ``logEvent(_:parameters:completion:)`` rather
    /// than a separate pipeline: it sends the event named `purchase` with
    /// `value` and `currency` set, and everything true of `logEvent` — the retry
    /// queue, the parameter limits, the device block — is true of this too.
    ///
    /// The wrapper exists because those two keys have to be spelled the same way
    /// by every caller. `logEvent` is untyped, so left to themselves one app
    /// sends `revenue`, another sends `"$49.99"`, and a conversion forwarder has
    /// to guess. Meta's Conversions API wants `custom_data.value` and
    /// `currency`; Google wants a conversion value and currency. This is the one
    /// spelling both can be built from.
    ///
    /// - Parameters:
    ///   - value: the amount, in `currency`. Rejected if negative or not finite
    ///     — a refund is not a negative purchase, it is a different event.
    ///   - currency: ISO-4217, e.g. `"USD"`. Case-insensitive.
    ///   - orderId: your own id for the transaction. Worth passing: it is what
    ///     Google deduplicates conversions on, and it is how you reconcile a
    ///     forwarded conversion against your own records.
    ///   - parameters: anything else you want on the event. May not contain the
    ///     keys this method sets.
    ///   - completion: receives true only when the service accepted the event.
    public static func logPurchase(
        value: Double,
        currency: String,
        orderId: String? = nil,
        quantity: Int? = nil,
        productId: String? = nil,
        parameters: [String: Any] = [:],
        completion: ((Bool) -> Void)? = nil
    ) {
        stateLock.lock()
        let ready = enabled
        stateLock.unlock()

        guard ready else {
            answer(false, to: completion)
            return
        }

        let purchase = DeeplinklyPurchase.build(
            value: value,
            currency: currency,
            orderId: orderId,
            quantity: quantity,
            productId: productId,
            parameters: parameters
        )
        if let rejection = purchase.rejection {
            Logger.w("Rejected purchase: \(rejection.reason)")
            answer(false, to: completion)
            return
        }

        logEvent(
            DeeplinklyPurchase.eventName,
            parameters: purchase.parameters ?? [:],
            completion: completion
        )
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

    /// Deletes Deeplinkly's locally stored identifiers, attribution, device
    /// profile, event/session state, pasteboard state, and pending queues.
    ///
    /// Tracking remains disabled after the reset so a deletion request cannot
    /// immediately mint and report a replacement identity. Call
    /// `setTrackingEnabled(true)` explicitly if the user later opts back in.
    @discardableResult
    public static func resetPrivacyData() -> Bool {
        PrivacyData.reset()
        return true
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

    // MARK: - Consent

    /// Reports the person's advertising-consent answers.
    ///
    /// These travel with every enrichment and are attached to conversions when
    /// they are forwarded to an ad network. Google requires both `adUserData`
    /// and `adPersonalization` to be ``ConsentState/granted`` before a
    /// conversion for an EEA or UK user may be used, and treats an absent
    /// answer differently from an explicit ``ConsentState/unknown`` — so report
    /// what you actually know rather than defaulting.
    ///
    /// ## What this does and does not do
    ///
    /// This records what the person agreed to *with your ad networks*. It does
    /// not change what the SDK collects — ``setAttributionLevel(_:)`` is that
    /// control, and the two are independent on purpose: an app can hold consent
    /// to describe the device while holding none to personalise ads on it, and
    /// the reverse.
    ///
    /// It is also unrelated to App Tracking Transparency. ATT governs the
    /// IDFA; this governs what may be done with a conversion once it is
    /// measured. An app needs to answer both questions, and the answers can
    /// differ.
    ///
    /// Consent survives sign-out and survives a restore onto a new device.
    /// ``clearUserData()`` does not touch it: signing out is not withdrawing
    /// consent. To record a withdrawal, call this again with
    /// ``ConsentState/denied`` — a value the forwarder acts on, where simply
    /// forgetting the answer would read as "this app has no consent model" and
    /// is a weaker statement, not a stronger one.
    ///
    /// ## Merging
    ///
    /// Each call merges. An argument left nil is left as it was, so you can
    /// report the EEA determination at launch and the two answers when your
    /// banner is answered. Re-reporting an unchanged answer costs nothing — it
    /// is detected and no enrichment is sent.
    ///
    /// - Parameters:
    ///   - adUserData: whether user data may be sent to ad networks for
    ///     measurement. Google Consent Mode's `ad_user_data`.
    ///   - adPersonalization: whether that data may be used to personalise
    ///     advertising. Google Consent Mode's `ad_personalization`.
    ///   - isEEA: whether you consider this person in scope for GDPR. Your app
    ///     knows this; we do not, and a geo-IP guess is not a consent record.
    /// - Returns: false only if the SDK is not initialised.
    @discardableResult
    public static func setConsent(
        adUserData: ConsentState? = nil,
        adPersonalization: ConsentState? = nil,
        isEEA: Bool? = nil
    ) -> Bool {
        stateLock.lock()
        let key = storedApiKey
        let ready = enabled
        stateLock.unlock()
        guard ready else { return false }

        // Nothing changed: the banner reported the same answer it did last
        // launch, which is the common case. Storing it again is harmless;
        // sending an enrichment for it every time is not.
        guard
            ConsentStore.merge(
                adUserData: adUserData,
                adPersonalization: adPersonalization,
                isEEA: isEEA)
        else { return true }

        // force, for the reason setUserData forces: a consent answer has
        // nothing to do with whether a link brought this person here, and
        // gating it on attribution evidence would mean organic installs never
        // reported consent at all.
        EnrichmentSender.sendOnce(
            attributionData: [:],
            source: EnrichmentSender.consentSource,
            apiKey: key,
            force: true
        )
        return true
    }

    // MARK: - Push token / uninstall measurement

    /// Supplies the device's push token so uninstalls can be measured.
    ///
    /// Neither iOS nor Android notifies a server when an app is removed. Every
    /// measurement provider detects it the same way: send a silent, contentless
    /// push periodically and read the failure — APNs answers 410 once the app
    /// is gone. Handing us the token is the whole of the app's part; nothing is
    /// displayed to the user, and a background content-available push needs no
    /// notification permission.
    ///
    /// Call it from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, or
    /// with the FCM token from `messaging(_:didReceiveRegistrationToken:)` if
    /// you use Firebase — passing ``PushProvider/fcm`` in that case, since the
    /// prober has to know which service the token addresses.
    ///
    /// ```swift
    /// func application(
    ///     _ application: UIApplication,
    ///     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    /// ) {
    ///     let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    ///     Deeplinkly.setPushToken(token)
    /// }
    /// ```
    ///
    /// ## Level
    ///
    /// `push_token` is a `full`-tier signal: a unique, stable, per-install
    /// identifier a server can address, which is what that tier means. An app
    /// running at ``AttributionLevel/reduced`` or below does not report it and
    /// does not get uninstall numbers. That is the level working as documented,
    /// not a defect.
    ///
    /// Pass nil to forget the token — for instance when the person turns push
    /// off entirely.
    ///
    /// - Returns: false only if the SDK is not initialised.
    @discardableResult
    public static func setPushToken(_ token: String?, provider: PushProvider = .apns) -> Bool {
        stateLock.lock()
        let key = storedApiKey
        let ready = enabled
        stateLock.unlock()
        guard ready else { return false }

        guard PushTokenStore.set(token, provider: provider) else { return true }

        EnrichmentSender.sendOnce(
            attributionData: [:],
            source: EnrichmentSender.pushTokenSource,
            apiKey: key,
            force: true
        )
        return true
    }

    // MARK: - Debug

    /// Turns on verbose console output under the `Deeplinkly` tag.
    /// Hash the identifying fields on this device before they are sent.
    ///
    /// Off by default. With it on, `user_email`, `user_phone`,
    /// `user_first_name` and `user_last_name` are SHA-256 hashed here and the
    /// plaintext never leaves the device. Everything else is unaffected, and
    /// what is stored locally is still what you supplied, so turning this back
    /// off restores the previous behaviour.
    ///
    /// **This costs attribution quality, and the trade is yours to make.** A
    /// digest is computed once, under one normalisation, and advertising
    /// destinations do not agree about phone formatting — so a conversion
    /// forwarded to a destination whose rules differ will not match. Without
    /// hashing the service normalises per destination from the value you sent;
    /// with it, that value is gone and it cannot. Enable this when a compliance
    /// requirement says plaintext must not reach a processor, not by default.
    ///
    /// Phone numbers are normalised by discarding non-digits. That folds
    /// `+44 20 7946 0000` and `442079460000` together but does not understand
    /// trunk prefixes, so send one consistent format.
    ///
    /// Only the four fields above are hashed. Gender, country and date of birth
    /// are not: their value ranges are small enough to reverse a digest by
    /// enumeration, so hashing them would cost storage and buy nothing.
    @discardableResult
    public static func setPIIHashingEnabled(_ enabled: Bool) -> Bool {
        stateLock.lock()
        // Self.enabled, not `enabled`: the parameter shadows the SDK's own
        // ready flag here.
        let ready = Self.enabled
        stateLock.unlock()
        guard ready else { return false }
        PIIHashing.setEnabled(enabled)
        Logger.d("PII hashing \(enabled ? "enabled" : "disabled")")
        return true
    }

    /// Whether ``setPIIHashingEnabled(_:)`` is on. Off unless it was turned on.
    public static func isPIIHashingEnabled() -> Bool { PIIHashing.isEnabled() }

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
