// PIIHashing.swift
import CommonCrypto
import Foundation

/// On-device SHA-256 hashing of the identifying fields, off by default.
///
/// Off by default deliberately, and the default is the interesting decision.
/// Hashing on the device is not obviously safer: a digest of a normalised email
/// is exactly the value Meta matches on, so anyone holding it holds the match
/// key. What it does buy is that plaintext never reaches our servers, which is
/// a requirement some compliance teams state outright and will not negotiate.
///
/// The cost is real and falls on attribution quality. A digest is computed
/// once, here, under one normalisation — and Meta and Google do not agree about
/// phone formatting. With hashing on, a conversion forwarded to a destination
/// whose rules differ from the ones below will not match, and the service can
/// no longer re-derive per destination because the value it would need is gone.
/// That trade is the customer's to make, which is why this is a switch and not
/// a default.
///
/// ## Which fields
///
/// Only ``hashedFields`` — email, phone, first and last name.
///
/// Hashing the others would be theatre. `user_gender` has two permitted values,
/// `user_country` about 250 and `user_date_of_birth` a few tens of thousands; a
/// digest over a domain that small is reversed by enumerating it. It would cost
/// real column width to store and buy no confidentiality at all.
///
/// ## Where it lives, and where it happens
///
/// `UserDefaults`, like ``ConsentStore`` and for the same reason: this is a
/// setting about *us*, not a fact about the person, so there is nothing here to
/// steal and it should survive a device restore. And, like consent, a
/// `clearUserData()` must not turn it off — signing out is not withdrawing a
/// compliance requirement.
///
/// The hashing itself happens at send time, not at store time. ``UserDataStore``
/// keeps what the app supplied, so the switch can be turned back off and a
/// value can still be normalised differently later if it was never hashed. The
/// raw value still never leaves the device, which is the whole promise.
///
/// The Kotlin twin is `PIIHashing`. Both must normalise identically, and so
/// must whatever resolves an erasure request, or a digest computed on this
/// device will not match the one an erasure is looked up by — and that failure
/// is silent. Change the rules below only together.
enum PIIHashing {

    static let storageKey = "dl_pii_hashing_enabled"

    /// Wire key reporting the mode to the service. `dynamic` in the catalogue.
    static let keyPIIHashingEnabled = "pii_hashing_enabled"

    /// The fields hashed when the switch is on.
    ///
    /// Derived names rather than literals so a rename cannot leave this
    /// pointing at a key that no longer exists.
    static let hashedFields: Set<String> = [
        DeeplinklyUserData.keyEmail,
        DeeplinklyUserData.keyPhone,
        DeeplinklyUserData.keyFirstName,
        DeeplinklyUserData.keyLastName,
    ]

    static func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: storageKey)
    }

    /// The value a digest is taken over, or nil when there is nothing to hash.
    ///
    /// Minimal on purpose. Phone strips every non-digit, which folds
    /// `+44 20 7946 0000` and `442079460000` together but does *not* understand
    /// country codes or trunk prefixes — `+44 (0)20 ...` keeps that `0` and
    /// hashes differently. Doing better needs a phone-number library and a
    /// default region, and there is no way to have identical ones in Kotlin,
    /// Swift, Dart and Python. An app turning this on must send one consistent
    /// format.
    static func normalize(_ field: String, _ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if field == DeeplinklyUserData.keyPhone {
            let digits = trimmed.filter { $0.isNumber && $0.isASCII }
            return digits.isEmpty ? nil : String(digits)
        }
        return trimmed.lowercased()
    }

    /// SHA-256 of the normalised value, lowercase hex, or nil.
    ///
    /// CommonCrypto rather than CryptoKit: `SHA256` is iOS 13+, and this SDK
    /// deploys to iOS 12. Raising the floor to get a nicer API would drop
    /// devices for every consumer, which is a much larger decision than this
    /// function deserves.
    static func digest(_ field: String, _ value: String) -> String? {
        guard let normalized = normalize(field, value),
            let data = normalized.data(using: .utf8)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &bytes)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Replaces the hashable fields of an outgoing payload with their digests.
    ///
    /// Returns `fields` unchanged when the switch is off.
    ///
    /// **Empty values are never hashed.** An empty string is a tombstone
    /// written by `clearUserData()` and read by the service as "null this
    /// column"; hashing it would produce a digest of nothing, which the service
    /// would store as a value and the erasure would silently not have happened.
    static func apply(_ fields: [String: String]) -> [String: String] {
        guard isEnabled() else { return fields }
        var out: [String: String] = [:]
        out.reserveCapacity(fields.count)
        for (key, value) in fields {
            if hashedFields.contains(key), !value.isEmpty {
                out[key] = digest(key, value) ?? value
            } else {
                out[key] = value
            }
        }
        return out
    }
}
