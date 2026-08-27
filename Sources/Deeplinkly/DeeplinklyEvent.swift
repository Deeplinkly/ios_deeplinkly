// DeeplinklyEvent.swift
import Foundation

/// Validation for `Deeplinkly.logEvent`.
///
/// A port of Android's `DeeplinklyEvent`, deliberately kept close enough to
/// read side by side. iOS enforced none of these rules while the public Dart
/// API documented them as "enforced natively rather than here", so a Flutter
/// app on iOS could send a 10KB event name, a hundred parameters, or keys
/// carrying the SDK's own reserved prefix — straight to the backend.
///
/// The limits are the documented ones and are asserted by the backend too;
/// changing one here without changing it there will start silently truncating.
enum DeeplinklyEvent {
    static let maxNameLength = 64
    static let maxParamsCount = 25
    static let maxParamKeyLength = 64
    static let maxParamValueLength = 256

    /// Reserved for the SDK's own bookkeeping (`_dl_event_seq`,
    /// `_dl_session_id`, …).
    ///
    /// The backend excludes this prefix from the caller's parameter budget, so
    /// letting a caller write one would both collide with the SDK's own values
    /// and smuggle parameters past the count limit.
    static let reservedParamPrefix = "_dl_"

    /// Keys any event may carry that mean something specific to us.
    ///
    /// Not `_dl_`-prefixed, so they cost a parameter and the tenant sees them in
    /// their dashboard, which is the point — the amount of a sale is the first
    /// thing someone reads off a purchase event. What the reservation buys is a
    /// *shape*: the backend lifts these two into typed columns, and Meta's
    /// `custom_data.value`/`currency` and Google's conversion value both want a
    /// number and a currency code rather than whatever a caller felt like.
    ///
    /// Checked here rather than only in `DeeplinklyPurchase` because `logEvent`
    /// is public and untyped: a caller who spells a purchase out by hand gets
    /// the same answer as one who uses the wrapper.
    static let valueParam = "value"
    static let currencyParam = "currency"

    /// Why an event was rejected. Surfaced only in debug logs.
    enum Rejection: Equatable {
        case emptyName
        case nameTooLong
        case tooManyParams
        case badKey(key: String, why: String)
        case badValue(key: String, why: String)

        var reason: String {
            switch self {
            case .emptyName:
                return "event name is blank"
            case .nameTooLong:
                return "event name exceeds \(maxNameLength) characters"
            case .tooManyParams:
                return "more than \(maxParamsCount) parameters"
            case .badKey(let key, let why):
                return "parameter key '\(key)': \(why)"
            case .badValue(let key, let why):
                return "parameter '\(key)': \(why)"
            }
        }
    }

    /// Checks `name` and `parameters` against the documented limits.
    ///
    /// Returns nil when the event is acceptable, or the reason it is not. Note
    /// that the caller's keys are trimmed *for the check only* — the map is
    /// forwarded exactly as supplied, matching Android and what Dart did.
    static func validate(name: String, parameters: [String: Any]) -> Rejection? {
        let normalized = normalizeName(name)
        if normalized.isEmpty { return .emptyName }
        if normalized.utf16.count > maxNameLength { return .nameTooLong }
        if parameters.count > maxParamsCount { return .tooManyParams }

        for (rawKey, value) in parameters {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { return .badKey(key: rawKey, why: "is blank") }
            if key.utf16.count > maxParamKeyLength {
                return .badKey(key: rawKey, why: "exceeds \(maxParamKeyLength) characters")
            }
            if key.hasPrefix(reservedParamPrefix) {
                return .badKey(
                    key: rawKey, why: "uses the reserved '\(reservedParamPrefix)' prefix")
            }
            if let rejection = validateReserved(key: key, value: value, rawKey: rawKey) {
                return rejection
            }
            if key == valueParam || key == currencyParam { continue }
            if let rejection = validate(value: value, forKey: rawKey) { return rejection }
        }
        return nil
    }

    /// The trimmed name actually sent, matching what Dart used to normalise.
    static func normalizeName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The shape checks for `value` and `currency`. Nil for every other key.
    private static func validateReserved(
        key: String, value: Any, rawKey: String
    ) -> Rejection? {
        if key == valueParam {
            // A Swift Bool bridges to NSNumber, so it has to be excluded before
            // the numeric check or `value: true` would be accepted as 1.
            guard let number = value as? NSNumber, !(value is Bool),
                CFGetTypeID(number) != CFBooleanGetTypeID()
            else {
                return .badValue(key: rawKey, why: "must be a number")
            }
            let amount = number.doubleValue
            if amount.isNaN || amount.isInfinite {
                return .badValue(key: rawKey, why: "must be finite")
            }
            if amount < 0 {
                return .badValue(key: rawKey, why: "must not be negative")
            }
            return nil
        }
        if key == currencyParam {
            guard let code = value as? String else {
                return .badValue(key: rawKey, why: "must be a string")
            }
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count == 3, trimmed.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                return .badValue(key: rawKey, why: "must be a 3-letter ISO-4217 code")
            }
            return nil
        }
        return nil
    }

    private static func validate(value: Any, forKey rawKey: String) -> Rejection? {
        // Order matters: NSString and NSNumber both satisfy several casts, and
        // a Swift Bool bridges to NSNumber. Strings are checked first so a
        // numeric-looking string is still measured as text.
        if let text = value as? String {
            return text.utf16.count > maxParamValueLength
                ? .badValue(key: rawKey, why: "exceeds \(maxParamValueLength) characters")
                : nil
        }
        // Covers Int, Double, Bool and every NSNumber that crosses the method
        // channel. Android accepts Number and Boolean with no length check;
        // so does this.
        if value is NSNumber { return nil }

        if value is [Any] || value is [String: Any] || value is [AnyHashable: Any] {
            // Containers are stored as compact JSON text, so it is the encoded
            // length the backend measures — and truncates.
            guard let encoded = try? encodeCompactJSON(value) else {
                return .badValue(key: rawKey, why: "is not JSON-encodable")
            }
            return encoded.utf16.count > maxParamValueLength
                ? .badValue(
                    key: rawKey,
                    why: "encodes to \(encoded.utf16.count) characters, "
                        + "over \(maxParamValueLength)")
                : nil
        }

        return .badValue(key: rawKey, why: "has unsupported type \(typeName(of: value))")
    }

    /// `null` is rejected rather than dropped, matching Android — a parameter
    /// the caller thought they were sending is a bug worth reporting, not
    /// something to silently omit.
    private static func typeName(of value: Any) -> String {
        if value is NSNull { return "null" }
        return String(describing: type(of: value))
    }

    private enum EncodingError: Error { case unsupported }

    /// Compact JSON, rejecting anything not representable.
    ///
    /// The tree is walked and type-checked before `JSONSerialization` sees it,
    /// for the same reason Android does not hand the map to `JSONObject`:
    /// letting the serialiser decide would either throw an ObjC exception that
    /// Swift cannot catch, or accept a value the backend cannot store.
    private static func encodeCompactJSON(_ value: Any) throws -> String {
        let sanitised = try toJSONValue(value)
        // .sortedKeys only to make the encoded length reproducible in tests;
        // key order does not change it.
        let data = try JSONSerialization.data(withJSONObject: sanitised, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingError.unsupported
        }
        return text
    }

    private static func toJSONValue(_ value: Any) throws -> Any {
        if value is NSNull { return NSNull() }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number }
        if let array = value as? [Any] { return try array.map(toJSONValue) }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = try toJSONValue(v) }
            return out
        }
        // A dictionary that is not String-keyed cannot be a JSON object, and
        // Android throws for the same case.
        if value is [AnyHashable: Any] { throw EncodingError.unsupported }
        throw EncodingError.unsupported
    }
}
