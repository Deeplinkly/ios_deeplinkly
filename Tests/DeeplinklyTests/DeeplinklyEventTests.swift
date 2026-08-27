import XCTest

@testable import Deeplinkly

/// The validation table for `Deeplinkly.logEvent`.
///
/// iOS enforced none of this before the facade existed — the bridge trimmed the
/// name, checked it was non-empty, and sent whatever else it was given. The
/// public Dart API documented the full rule set as "enforced natively rather
/// than here", so every one of these cases reached a production backend.
///
/// Mirrors Android's `DeeplinklyEventTest`. The limits are asserted by the
/// backend too, so a change here that is not made there starts silently
/// truncating — which is why the numbers are spelled out rather than derived
/// from the constants.
final class DeeplinklyEventTests: XCTestCase {

    private func validate(_ name: String, _ params: [String: Any] = [:])
        -> DeeplinklyEvent.Rejection?
    {
        DeeplinklyEvent.validate(name: name, parameters: params)
    }

    // MARK: - Name

    func testAPlainNameIsAccepted() {
        XCTAssertNil(validate("purchase"))
    }

    func testAnEmptyNameIsRejected() {
        XCTAssertEqual(validate(""), .emptyName)
    }

    func testAWhitespaceOnlyNameIsRejected() {
        XCTAssertEqual(validate("   \n\t "), .emptyName)
    }

    func testANameIsTrimmedBeforeBeingMeasured() {
        // 64 characters of content with padding either side: the padding must
        // not push it over the limit.
        let name = "  " + String(repeating: "a", count: 64) + "  "
        XCTAssertNil(validate(name))
        XCTAssertEqual(DeeplinklyEvent.normalizeName(name).count, 64)
    }

    func testANameOfExactlySixtyFourIsAccepted() {
        XCTAssertNil(validate(String(repeating: "a", count: 64)))
    }

    func testANameOfSixtyFiveIsRejected() {
        XCTAssertEqual(validate(String(repeating: "a", count: 65)), .nameTooLong)
    }

    // MARK: - Parameter count

    func testTwentyFiveParametersAreAccepted() {
        var params: [String: Any] = [:]
        for i in 0..<25 { params["k\(i)"] = i }
        XCTAssertNil(validate("e", params))
    }

    func testTwentySixParametersAreRejected() {
        var params: [String: Any] = [:]
        for i in 0..<26 { params["k\(i)"] = i }
        XCTAssertEqual(validate("e", params), .tooManyParams)
    }

    // MARK: - Parameter keys

    func testABlankKeyIsRejected() {
        XCTAssertEqual(validate("e", ["  ": 1]), .badKey(key: "  ", why: "is blank"))
    }

    func testAKeyOfExactlySixtyFourIsAccepted() {
        XCTAssertNil(validate("e", [String(repeating: "k", count: 64): 1]))
    }

    func testAKeyOfSixtyFiveIsRejected() {
        let key = String(repeating: "k", count: 65)
        XCTAssertEqual(
            validate("e", [key: 1]), .badKey(key: key, why: "exceeds 64 characters"))
    }

    /// The one rule with teeth beyond tidiness: the backend excludes this
    /// prefix from the caller's 25-parameter budget, so a caller writing one
    /// both collides with the SDK's own bookkeeping and smuggles parameters
    /// past the count limit.
    func testTheReservedPrefixIsRejected() {
        XCTAssertEqual(
            validate("e", ["_dl_event_seq": "1"]),
            .badKey(key: "_dl_event_seq", why: "uses the reserved '_dl_' prefix"))
    }

    func testTheReservedPrefixIsRejectedAfterTrimming() {
        // Trimmed for the check, so padding does not smuggle it past.
        XCTAssertEqual(
            validate("e", ["  _dl_sneaky": "1"]),
            .badKey(key: "  _dl_sneaky", why: "uses the reserved '_dl_' prefix"))
    }

    func testAKeyMerelyContainingTheReservedPrefixIsFine() {
        XCTAssertNil(validate("e", ["not_dl_reserved": 1]))
    }

    /// Keys are trimmed for the check only. The map is forwarded exactly as
    /// supplied, matching Android and what Dart did — so a caller who sent a
    /// padded key still gets that padded key in their dashboard.
    func testKeysAreTrimmedForTheCheckOnly() {
        let padded = "  spaced  "
        XCTAssertNil(validate("e", [padded: 1]))
    }

    // MARK: - Parameter values

    func testStringNumberAndBoolValuesAreAccepted() {
        XCTAssertNil(
            validate(
                "e",
                [
                    "s": "text", "i": 42, "d": 4.2, "b": true, "negative": -1,
                ]))
    }

    func testAStringOfExactlyTwoFiftySixIsAccepted() {
        XCTAssertNil(validate("e", ["k": String(repeating: "v", count: 256)]))
    }

    func testAStringOfTwoFiftySevenIsRejected() {
        XCTAssertEqual(
            validate("e", ["k": String(repeating: "v", count: 257)]),
            .badValue(key: "k", why: "exceeds 256 characters"))
    }

    func testALongNumberIsNotLengthChecked() {
        // Numbers carry no length rule on either platform.
        XCTAssertNil(validate("e", ["k": Double.greatestFiniteMagnitude]))
    }

    func testNullIsRejectedRatherThanDropped() {
        XCTAssertEqual(
            validate("e", ["k": NSNull()]),
            .badValue(key: "k", why: "has unsupported type null"))
    }

    func testAnUnsupportedTypeIsRejected() {
        let rejection = validate("e", ["k": Date()])
        guard case .badValue(let key, let why)? = rejection else {
            return XCTFail("expected a badValue rejection, got \(String(describing: rejection))")
        }
        XCTAssertEqual(key, "k")
        XCTAssertTrue(
            why.hasPrefix("has unsupported type"), "unexpected reason: \(why)")
    }

    // MARK: - Container values

    func testASmallListIsAccepted() {
        XCTAssertNil(validate("e", ["k": [1, 2, 3]]))
    }

    func testASmallMapIsAccepted() {
        XCTAssertNil(validate("e", ["k": ["a": 1, "b": "two"]]))
    }

    func testANestedContainerIsAccepted() {
        XCTAssertNil(validate("e", ["k": ["a": [1, 2, ["b": true]]]]))
    }

    /// Containers are measured as their compact JSON encoding, because that is
    /// what the backend stores and truncates — not by element count.
    func testAContainerIsMeasuredByItsEncodedLength() {
        // 60 four-character strings encode to well over 256 characters while
        // being only 60 elements.
        let big = Array(repeating: "abcd", count: 60)
        let rejection = validate("e", ["k": big])
        guard case .badValue(let key, let why)? = rejection else {
            return XCTFail("expected a badValue rejection, got \(String(describing: rejection))")
        }
        XCTAssertEqual(key, "k")
        XCTAssertTrue(why.contains("over 256"), "unexpected reason: \(why)")
    }

    func testAContainerJustUnderTheLimitIsAccepted() {
        // ["aaa…"] — one string, encoded as 2 brackets + 2 quotes + content.
        let value = [String(repeating: "a", count: 252)]
        XCTAssertNil(validate("e", ["k": value]))
    }

    func testAContainerJustOverTheLimitIsRejected() {
        let value = [String(repeating: "a", count: 253)]
        XCTAssertNotNil(validate("e", ["k": value]))
    }

    func testAContainerHoldingAnUnencodableValueIsRejected() {
        XCTAssertEqual(
            validate("e", ["k": [Date()]]),
            .badValue(key: "k", why: "is not JSON-encodable"))
    }

    func testAMapWithNonStringKeysIsRejected() {
        let value: [AnyHashable: Any] = [1: "one"]
        XCTAssertEqual(
            validate("e", ["k": value]),
            .badValue(key: "k", why: "is not JSON-encodable"))
    }

    func testAContainerMayHoldNull() {
        // Null is rejected as a top-level parameter value but is legal JSON
        // inside a container, which is how Android behaves too.
        XCTAssertNil(validate("e", ["k": [1, NSNull(), 3]]))
    }

    // MARK: - Reasons

    /// The reasons are debug-log only, but a rejection with an unreadable
    /// reason is a support call, so they are pinned.
    func testReasonsReadAsSentences() {
        XCTAssertEqual(DeeplinklyEvent.Rejection.emptyName.reason, "event name is blank")
        XCTAssertEqual(
            DeeplinklyEvent.Rejection.nameTooLong.reason,
            "event name exceeds 64 characters")
        XCTAssertEqual(
            DeeplinklyEvent.Rejection.tooManyParams.reason, "more than 25 parameters")
        XCTAssertEqual(
            DeeplinklyEvent.Rejection.badKey(key: "k", why: "is blank").reason,
            "parameter key 'k': is blank")
        XCTAssertEqual(
            DeeplinklyEvent.Rejection.badValue(key: "k", why: "is odd").reason,
            "parameter 'k': is odd")
    }

    // MARK: - Limits

    /// The backend asserts the same numbers. Changing one here without changing
    /// it there starts silently truncating, so they are pinned as literals
    /// rather than read from the constants they guard.
    func testTheDocumentedLimitsAreUnchanged() {
        XCTAssertEqual(DeeplinklyEvent.maxNameLength, 64)
        XCTAssertEqual(DeeplinklyEvent.maxParamsCount, 25)
        XCTAssertEqual(DeeplinklyEvent.maxParamKeyLength, 64)
        XCTAssertEqual(DeeplinklyEvent.maxParamValueLength, 256)
        XCTAssertEqual(DeeplinklyEvent.reservedParamPrefix, "_dl_")
    }

    // MARK: - Reserved revenue keys

    /// `value` and `currency` are checked on the plain `logEvent` path, not only
    /// inside `DeeplinklyPurchase`. `logEvent` is public and untyped, so a
    /// caller who spells a purchase out by hand has to get the same answer as
    /// one who used the wrapper — otherwise the backend's typed columns fill
    /// with whatever the hand-rolled path felt like sending.
    func testAcceptsANumericValueAndAThreeLetterCurrency() {
        XCTAssertNil(
            DeeplinklyEvent.validate(
                name: "purchase", parameters: ["value": 49.99, "currency": "USD"]))
        XCTAssertNil(
            DeeplinklyEvent.validate(
                name: "purchase", parameters: ["value": 49, "currency": "eur"]))
    }

    func testRejectsAValueThatIsNotANumber() {
        XCTAssertNotNil(
            DeeplinklyEvent.validate(name: "purchase", parameters: ["value": "49.99"]))
    }

    /// Bool bridges to NSNumber on this platform, so `true` would otherwise be
    /// accepted as a sale worth 1.
    func testRejectsABooleanValue() {
        XCTAssertNotNil(
            DeeplinklyEvent.validate(name: "purchase", parameters: ["value": true]))
    }

    func testRejectsANegativeOrNonFiniteValue() {
        XCTAssertNotNil(
            DeeplinklyEvent.validate(name: "purchase", parameters: ["value": -1.0]))
        XCTAssertNotNil(
            DeeplinklyEvent.validate(name: "purchase", parameters: ["value": Double.nan]))
        XCTAssertNotNil(
            DeeplinklyEvent.validate(
                name: "purchase", parameters: ["value": Double.infinity]))
    }

    func testRejectsACurrencyThatIsNotAnISO4217Shape() {
        XCTAssertNotNil(
            DeeplinklyEvent.validate(name: "purchase", parameters: ["currency": "dollars"]))
        XCTAssertNotNil(
            DeeplinklyEvent.validate(name: "purchase", parameters: ["currency": 840]))
    }

    /// They are ordinary parameters otherwise: no `_dl_` exemption.
    func testTheRevenueKeysStillCountAgainstTheParameterBudget() {
        var params: [String: Any] = [:]
        for i in 1...24 { params["k\(i)"] = "v" }
        params["value"] = 1.0
        params["currency"] = "USD"
        XCTAssertNotNil(DeeplinklyEvent.validate(name: "purchase", parameters: params))
    }
}
