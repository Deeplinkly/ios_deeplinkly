// PushTokenStore.swift
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Which push service a token addresses, so the prober knows what to speak.
///
/// An iOS app is normally ``apns``, but a Flutter or React Native app shares
/// one store across both platforms, so the value is explicit rather than
/// inferred from the SDK it was set through.
@objc public enum PushProvider: Int, CaseIterable, Sendable {
    /// Apple Push Notification service.
    case apns

    /// Firebase Cloud Messaging — an iOS app using the Firebase SDK hands out
    /// an FCM token rather than the raw APNs one, and the prober has to know.
    case fcm

    public var wireName: String {
        switch self {
        case .apns: return "apns"
        case .fcm: return "fcm"
        }
    }

    public static func fromWireName(_ value: String?) -> PushProvider? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !text.isEmpty
        else { return nil }
        return allCases.first { $0.wireName == text }
    }
}

/// The push token the host app last handed us, used to measure uninstalls.
///
/// ## How the measurement works, and why the token is the whole of the SDK's part
///
/// There is no uninstall callback on either platform. Every measurement
/// provider detects one the same way: send a silent, contentless push to the
/// device periodically and read the failure. APNs answers 410 `Unregistered`
/// and FCM answers `UNREGISTERED` once the app is gone. That is a server-side
/// probe against a stored token, so the only thing that must be compiled into
/// the app is getting the token out — which is why this ships in a build that
/// goes out months before the prober does.
///
/// ## Why the token is FULL tier
///
/// A push token is a unique, stable, per-install identifier that a server can
/// address. That is the definition of the tier, and classifying it lower
/// because uninstall measurement is a nice feature would be exactly the
/// misclassification the catalogue exists to prevent. Apps running at
/// ``AttributionLevel/reduced`` or below do not report it and do not get
/// uninstall numbers; that is the level working, not a defect.
///
/// ## Why `UserDefaults` and not the Keychain
///
/// The opposite call from ``ConsentStore``, for the opposite reason. A Keychain
/// item under `thisDeviceOnly` would be right for something that must not
/// travel; a push token positively *must not survive* onto other hardware, and
/// `UserDefaults` restoring from a backup is precisely the hazard. The token is
/// therefore stamped with the install it was issued for and dropped when that
/// stamp does not match — see ``get()``.
enum PushTokenStore {
    static let tokenKey = "dl_push_token"
    static let providerKey = "dl_push_provider"

    /// The install the stored token was issued for.
    ///
    /// iOS restores `UserDefaults` from an encrypted or iCloud backup onto a
    /// *different physical device*, which brings the token with it — and a
    /// token addressing the old handset either manufactures an uninstall that
    /// never happened or points the prober at someone else's phone. Android
    /// gets this guard for free from `InstallIdentity`; iOS has no equivalent
    /// sweep, so it is local.
    ///
    /// Stamped with `identifierForVendor` for the reason `DeviceProfile` names:
    /// it is the component that actually changes on a restore to new hardware.
    /// The Keychain device id would not do — a Keychain item is itself carried
    /// into a backup, so both halves would travel together and the stamp would
    /// match on the new phone, which is exactly the case this exists to catch.
    static let installKey = "dl_push_token_install"

    /// Never sent, and never stored raw. Only ever compared with itself, so a
    /// `full`-tier identifier does not need to sit in the plist in the clear at
    /// every attribution level — the same argument `InstallIdentity` makes on
    /// Android for hashing the SSAID.
    private static func currentInstallStamp() -> String {
        #if canImport(UIKit)
            let idfv = UIDevice.current.identifierForVendor?.uuidString ?? ""
        #else
            let idfv = ""
        #endif
        return EnrichmentSender.stableDigest(idfv)
    }

    /// Longest token accepted. Must match `push_token`'s `max_len` in
    /// `tool/signals.json`, which is where the service truncates — the
    /// generated `SignalCatalogue` carries tier and scope but not lengths, so
    /// this constant is what keeps the two in step. Pinned by
    /// `PushTokenStoreTests`.
    ///
    /// 512 is generous on purpose: APNs device tokens are 64 hex characters and
    /// FCM tokens run 160-260, but neither is specified as bounded and a token
    /// that grows is better truncated by the service than dropped here.
    static let maxLength = 512

    /// Stores a token.
    ///
    /// A nil or blank token removes what is held rather than storing an empty
    /// string — the host app calling this with nil is saying the device has no
    /// token, and an empty value on the wire would be read by the service as an
    /// erasure of a column that should simply stop being sent.
    ///
    /// - Returns: true if the stored value changed. Tokens rotate rarely and
    ///   apps re-report them on every launch; an unchanged report must not
    ///   produce an enrichment.
    @discardableResult
    static func set(_ token: String?, provider: PushProvider) -> Bool {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmed.isEmpty {
            if Prefs.string(for: tokenKey) == nil { return false }
            Prefs.set(nil as String?, for: tokenKey)
            Prefs.set(nil as String?, for: providerKey)
            Prefs.set(nil as String?, for: installKey)
            return true
        }

        if trimmed.count > maxLength {
            Logger.w(
                "PushTokenStore: token is \(trimmed.count) chars, over the "
                    + "\(maxLength) the catalogue allows; ignoring it")
            return false
        }

        let install = currentInstallStamp()
        if Prefs.string(for: tokenKey) == trimmed,
            Prefs.string(for: providerKey) == provider.wireName,
            Prefs.string(for: installKey) == install
        {
            return false
        }

        Prefs.set(trimmed, for: tokenKey)
        Prefs.set(provider.wireName, for: providerKey)
        Prefs.set(install, for: installKey)
        return true
    }

    /// Fields to merge into the enrichment payload. Empty when unset, and empty
    /// when the stored token belongs to a different install — see ``installKey``.
    static func get() -> [String: String] {
        guard let token = Prefs.string(for: tokenKey), !token.isEmpty else { return [:] }

        guard Prefs.string(for: installKey) == currentInstallStamp() else {
            Logger.w("PushTokenStore: token belongs to another install; dropping it")
            purge()
            return [:]
        }

        let provider = Prefs.string(for: providerKey) ?? PushProvider.apns.wireName
        return ["push_token": token, "push_provider": provider]
    }

    static func purge() {
        Prefs.set(nil as String?, for: tokenKey)
        Prefs.set(nil as String?, for: providerKey)
        Prefs.set(nil as String?, for: installKey)
    }
}
