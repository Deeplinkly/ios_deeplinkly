// ConsentState.swift
import Foundation

/// A single advertising-consent answer, in Google's vocabulary.
///
/// These are not Deeplinkly's invention and are deliberately not renamed: they
/// are the values Google Ads accepts on an uploaded conversion (`GRANTED`,
/// `DENIED`, `UNKNOWN`), so carrying them verbatim means the forwarder does no
/// translation and there is no mapping table to get backwards.
///
/// ## Why `unknown` is not the same as never calling setConsent
///
/// ``unknown`` is a positive statement: the app asked, or had the chance to,
/// and has no answer — a banner dismissed without a choice, a returning user
/// whose stored decision expired. Never calling ``Deeplinkly/setConsent(adUserData:adPersonalization:isEEA:)``
/// at all leaves the field absent, which says the app has no consent model
/// wired up.
///
/// Google treats those differently (absent is `CONSENT_UNSPECIFIED`), so the
/// distinction survives to the wire rather than being flattened here. That is
/// also why there is no `notSet` case: absence is expressed by not setting the
/// field, not by a fourth case every layer would have to special-case.
@objc public enum ConsentState: Int, CaseIterable, Sendable {
    /// The person agreed.
    case granted

    /// The person declined.
    case denied

    /// Asked, no answer. See the note above on why this is not absence.
    case unknown

    /// The value sent on the wire, and the one Google Ads expects.
    public var wireName: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .unknown: return "unknown"
        }
    }

    /// Parses a wire name back, case-insensitively. Nil if unrecognised.
    public static func fromWireName(_ value: String?) -> ConsentState? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !text.isEmpty
        else { return nil }
        return allCases.first { $0.wireName == text }
    }
}
