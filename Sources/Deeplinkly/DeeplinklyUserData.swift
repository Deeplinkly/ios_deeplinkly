// DeeplinklyUserData.swift
import Foundation

/// Validation and normalisation for `Deeplinkly.setUserData`.
///
/// A port of Android's `DeeplinklyUserData`, deliberately kept close enough to
/// read side by side.
///
/// These are the fields a conversion is matched on once it reaches Meta's
/// Conversions API or Google's enhanced conversions. This platform is where
/// that matters most: with App Tracking Transparency denied there is no IDFA,
/// so a hashed email is the only match key that still exists and a value
/// dropped here is a conversion that goes unattributed.
///
/// ## Nothing is hashed here
///
/// Values are stored and sent as the host app supplied them, and hashed only
/// when a conversion is forwarded. Hashing on device would look like the safer
/// choice and buy nothing: SHA-256 of a normalised email is not one-way against
/// an address someone already has — it is precisely the value Meta matches on,
/// so anyone holding the digest holds the match key. Keeping the plaintext is
/// what lets the backend normalise per destination (Meta and Google disagree
/// about phone formatting) and re-derive when a platform changes its rules.
///
/// ## Normalisation is deliberately shallow
///
/// Trimming only, except where a value has to fit a column that cannot hold the
/// alternative. Lowercasing an email, or stripping punctuation out of a name,
/// is a destination's rule rather than a fact about the value, and doing it
/// here would throw away what the app actually knows before the backend can
/// decide what each destination wants.
///
/// The three constrained fields are the exception. `user_gender` is one
/// character, `user_country` is two and `user_date_of_birth` is ten; a value
/// that does not fit is rejected rather than truncated, because the truncation
/// of "non-binary" is "n", which is a value Meta would happily match on and
/// would be wrong.
enum DeeplinklyUserData {

    /// Wire key for the host app's own identifier for the person.
    static let keyUserId = "custom_user_id"

    static let keyEmail = "user_email"
    static let keyPhone = "user_phone"
    static let keyFirstName = "user_first_name"
    static let keyLastName = "user_last_name"
    static let keyDateOfBirth = "user_date_of_birth"
    static let keyGender = "user_gender"
    static let keyStreet = "user_street"
    static let keyCity = "user_city"
    static let keyState = "user_state"
    static let keyZip = "user_zip"
    static let keyCountry = "user_country"

    /// Every `user_*` key, and the length the catalogue gives it.
    ///
    /// `custom_user_id` is absent on purpose: it is user-scoped in the
    /// catalogue too, but it has always been stored in its own preference and
    /// read from there by the header path, so `UserDataStore` does not own a
    /// second copy. See `Deeplinkly.setUserData`.
    static let maxLengths: [String: Int] = [
        keyEmail: 320,
        keyPhone: 32,
        keyFirstName: 128,
        keyLastName: 128,
        keyDateOfBirth: 10,
        keyGender: 1,
        keyStreet: 256,
        keyCity: 128,
        keyState: 128,
        keyZip: 32,
        keyCountry: 2,
    ]

    /// The keys `UserDataStore` may hold.
    static var keys: Set<String> { Set(maxLengths.keys) }

    /// Why a call to `Deeplinkly.setUserData` was rejected. Debug logs only.
    struct Rejection: Equatable {
        let reason: String
    }

    /// Either the normalised fields or the reason there are none.
    struct Result {
        let fields: [String: String]?
        let rejection: Rejection?
    }

    /// Normalises one field, or explains why it cannot be stored.
    ///
    /// A blank value answers `(nil, nil)`: the caller passed nothing for this
    /// field, which merges as "leave whatever is there alone".
    static func normalize(
        _ key: String, _ raw: String?
    ) -> (value: String?, rejection: Rejection?) {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return (nil, nil) }

        let normalized: String
        switch key {
        case keyCountry:
            // Uppercased rather than rejected for case: an app that stores "us"
            // is not making a mistake, and ISO-3166-1 alpha-2 is defined
            // uppercase.
            normalized = value.uppercased()
        case keyGender:
            // Meta's `ge` is "m" or "f". Anything else is not a narrower
            // vocabulary we can coerce into, so it is refused rather than
            // mangled into a letter that means something we were not told.
            let lowered = value.lowercased()
            guard lowered == "m" || lowered == "f" else {
                return (nil, Rejection(reason: "\(key) must be \"m\" or \"f\"; got \"\(value)\""))
            }
            normalized = lowered
        case keyDateOfBirth:
            guard isISODate(value) else {
                return (nil, Rejection(reason: "\(key) must be YYYY-MM-DD; got \"\(value)\""))
            }
            normalized = value
        default:
            normalized = value
        }

        guard let limit = maxLengths[key] else {
            return (nil, Rejection(reason: "\(key) is not a user-data field"))
        }
        if normalized.utf16.count > limit {
            return (
                nil,
                Rejection(
                    reason: "\(key) exceeds \(limit) characters (\(normalized.utf16.count))")
            )
        }
        return (normalized, nil)
    }

    /// Normalises a whole call.
    ///
    /// All or nothing: one bad field rejects the call rather than storing the
    /// rest, so a caller is never left guessing which of the twelve values
    /// actually took. Keys whose value is nil or blank are simply absent from
    /// the result, which is what makes `Deeplinkly.setUserData` merge.
    static func normalizeAll(_ fields: [String: String?]) -> Result {
        var out: [String: String] = [:]
        // Sorted so a call with two bad fields reports the same one every time.
        for key in fields.keys.sorted() {
            let (value, rejection) = normalize(key, fields[key] ?? nil)
            if let rejection { return Result(fields: nil, rejection: rejection) }
            if let value { out[key] = value }
        }
        return Result(fields: out, rejection: nil)
    }

    /// `YYYY-MM-DD`, checked by shape rather than by parsing.
    ///
    /// A `DateFormatter` would also accept, and silently rewrite, a range of
    /// nearby spellings depending on the device's calendar and locale. The
    /// shape is the contract.
    private static func isISODate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let widths = [4, 2, 2]
        for (part, width) in zip(parts, widths) {
            guard part.count == width, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber)
            else { return false }
        }
        return true
    }
}
