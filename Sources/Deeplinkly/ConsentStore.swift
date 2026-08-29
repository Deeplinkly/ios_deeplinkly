// ConsentStore.swift
import Foundation

/// The advertising-consent state the host app last reported.
///
/// ## Where this lives
///
/// `UserDefaults`, not the Keychain — deliberately the opposite call from
/// ``UserDataStore``. That store holds an email address and a postal address,
/// which is why it moved. This holds three enum values describing a choice
/// about advertising; there is nothing here to steal, and the plist's one
/// meaningful property — that it is carried into a device backup — is a
/// *feature* for a consent record. The answer should survive the person
/// restoring onto a new phone, because it is still the same person and still
/// the same decision.
///
/// One key holding one JSON object, for the reason ``UserDataStore`` gives:
/// `PrivacyData.persistedKeys` is a hand-maintained inventory of everything the
/// SDK writes, and three separately-named keys would be three chances to miss
/// one.
///
/// ## Why these are not `user` scope in the catalogue
///
/// Consent is not a fact about the person the way an email address is — it is a
/// decision about *us*. Two consequences follow, and both are why these keys
/// are classified `dynamic` and stored here rather than in ``UserDataStore``:
///
///  - `clearUserData()` must not wipe it. Signing out is not withdrawing
///    consent, and a consent record that vanishes on sign-out is the one a
///    regulator asks about.
///  - It must not be redacted out of error logs. `PII_KEY_NAMES` on the service
///    is derived from the catalogue's `user` scope, so anything classified
///    there disappears from a stored request body — correct for an email
///    address, and exactly wrong for the field you need in order to answer
///    "why was this conversion not forwarded".
///
/// ## Merging
///
/// ``merge(adUserData:adPersonalization:isEEA:)`` leaves an argument that was
/// not supplied alone, so an app can report the EEA determination at launch and
/// the two answers when its banner is answered.
///
/// There is no `clear()`. Withdrawing consent is ``ConsentState/denied``, a
/// value the forwarder must see and act on; deleting the record instead would
/// read downstream as "this app has no consent model", which is a different and
/// much weaker statement.
enum ConsentStore {
    static let storageKey = "dl_consent"

    static let keyAdUserData = "consent_ad_user_data"
    static let keyAdPersonalization = "consent_ad_personalization"
    static let keyIsEEA = "consent_is_eea"

    private static let keys = [keyAdUserData, keyAdPersonalization, keyIsEEA]

    /// Fields to merge into the enrichment payload. Empty when nothing is set.
    static func get() -> [String: String] {
        guard let raw = Prefs.string(for: storageKey),
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            if Prefs.string(for: storageKey) != nil {
                Logger.w("ConsentStore: unreadable payload, discarding")
                Prefs.set(nil as String?, for: storageKey)
            }
            return [:]
        }

        var out: [String: String] = [:]
        for key in keys {
            if let value = json[key] as? String { out[key] = value }
        }
        return out
    }

    /// Merges the supplied answers over what is stored. Nils are left alone.
    ///
    /// - Returns: true if anything changed. The caller uses this to decide
    ///   whether a send is worth making: a consent banner that re-reports the
    ///   same answer on every launch is the common case, and it must not
    ///   produce an enrichment every time.
    @discardableResult
    static func merge(
        adUserData: ConsentState?,
        adPersonalization: ConsentState?,
        isEEA: Bool?
    ) -> Bool {
        if adUserData == nil && adPersonalization == nil && isEEA == nil { return false }

        let current = get()
        var next = current
        if let adUserData { next[keyAdUserData] = adUserData.wireName }
        if let adPersonalization { next[keyAdPersonalization] = adPersonalization.wireName }
        if let isEEA { next[keyIsEEA] = isEEA ? "true" : "false" }

        if next == current { return false }

        guard let data = try? JSONSerialization.data(withJSONObject: next),
            let encoded = String(data: data, encoding: .utf8)
        else { return false }

        Prefs.set(encoded, for: storageKey)
        return true
    }

    /// Whether the host app has ever reported a consent answer.
    static func isEmpty() -> Bool { get().isEmpty }

    static func purge() {
        Prefs.set(nil as String?, for: storageKey)
    }
}
