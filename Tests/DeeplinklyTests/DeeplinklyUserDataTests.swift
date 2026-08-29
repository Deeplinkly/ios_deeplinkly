import XCTest

@testable import Deeplinkly

/// The normalisation contract behind `Deeplinkly.setUserData`.
///
/// These values become the match keys a conversion is joined on at Meta and
/// Google. A field silently mangled here does not fail loudly later — it matches
/// nobody, and the conversion is simply never attributed, which looks exactly
/// like the campaign not working.
///
/// The Kotlin twin is `DeeplinklyUserDataTest`; the two are meant to be read
/// side by side, and a case added to one belongs in the other.
final class DeeplinklyUserDataTests: XCTestCase {

    func testTrimsButDoesNotOtherwiseTouchFreeTextFields() {
        let (value, rejection) = DeeplinklyUserData.normalize(
            DeeplinklyUserData.keyEmail, "  Ada@Example.COM ")
        XCTAssertNil(rejection)
        // Not lowercased. Lowercasing is Meta's rule, not a fact about the
        // address, and the service can apply it per destination only if we did
        // not already throw the original away.
        XCTAssertEqual(value, "Ada@Example.COM")
    }

    func testBlankMeansLeaveAloneRatherThanClear() {
        let (value, rejection) = DeeplinklyUserData.normalize(
            DeeplinklyUserData.keyFirstName, "   ")
        XCTAssertNil(rejection)
        XCTAssertNil(value)
    }

    func testUppercasesACountryCode() {
        let (value, rejection) = DeeplinklyUserData.normalize(
            DeeplinklyUserData.keyCountry, "us")
        XCTAssertNil(rejection)
        XCTAssertEqual(value, "US")
    }

    func testRejectsACountryThatIsNotTwoLetters() {
        let (value, rejection) = DeeplinklyUserData.normalize(
            DeeplinklyUserData.keyCountry, "USA")
        XCTAssertNotNil(rejection)
        XCTAssertNil(value)
    }

    func testAcceptsTheTwoGenderValuesMetaMatchesOn() {
        XCTAssertEqual(
            DeeplinklyUserData.normalize(DeeplinklyUserData.keyGender, "M").value, "m")
        XCTAssertEqual(
            DeeplinklyUserData.normalize(DeeplinklyUserData.keyGender, "f").value, "f")
    }

    /// The case that motivates rejecting rather than truncating: the column is
    /// one character, so a truncated "non-binary" would be stored as "n" — not
    /// merely lossy but wrong, and a forwarder would pass it on as if we had
    /// been told it.
    func testRefusesAGenderItCannotRepresentInsteadOfTruncatingIt() {
        let (value, rejection) = DeeplinklyUserData.normalize(
            DeeplinklyUserData.keyGender, "non-binary")
        XCTAssertNotNil(rejection)
        XCTAssertNil(value)
    }

    func testRequiresAnISODateOfBirth() {
        XCTAssertNil(
            DeeplinklyUserData.normalize(DeeplinklyUserData.keyDateOfBirth, "1990-01-02")
                .rejection)
        XCTAssertNotNil(
            DeeplinklyUserData.normalize(DeeplinklyUserData.keyDateOfBirth, "02/01/1990")
                .rejection)
        XCTAssertNotNil(
            DeeplinklyUserData.normalize(DeeplinklyUserData.keyDateOfBirth, "1990-1-2")
                .rejection)
    }

    func testRejectsAValueLongerThanItsColumn() {
        XCTAssertNotNil(
            DeeplinklyUserData.normalize(
                DeeplinklyUserData.keyEmail, String(repeating: "a", count: 321)
            ).rejection)
        XCTAssertNil(
            DeeplinklyUserData.normalize(
                DeeplinklyUserData.keyEmail, String(repeating: "a", count: 320)
            ).rejection)
    }

    func testNormalizeAllDropsAbsentFieldsSoACallMerges() {
        let result = DeeplinklyUserData.normalizeAll([
            DeeplinklyUserData.keyEmail: "ada@example.com",
            DeeplinklyUserData.keyCity: nil,
            DeeplinklyUserData.keyZip: "",
        ])
        XCTAssertNil(result.rejection)
        XCTAssertEqual(result.fields, [DeeplinklyUserData.keyEmail: "ada@example.com"])
    }

    /// All or nothing. A caller who gets `false` back has to be able to assume
    /// nothing was stored, or they cannot recover — they would have to guess
    /// which of twelve values took.
    func testOneBadFieldRejectsTheWholeCall() {
        let result = DeeplinklyUserData.normalizeAll([
            DeeplinklyUserData.keyEmail: "ada@example.com",
            DeeplinklyUserData.keyCountry: "United States",
        ])
        XCTAssertNotNil(result.rejection)
        XCTAssertNil(result.fields)
    }

    /// `custom_user_id` is user-scoped in the catalogue but is deliberately not
    /// one of these: it has always lived in its own preference, and a second
    /// copy here would be a second thing to keep in step.
    func testTheCustomUserIdIsNotAUserDataStoreField() {
        XCTAssertFalse(DeeplinklyUserData.keys.contains(DeeplinklyUserData.keyUserId))
    }

    /// The catalogue is the contract these widths come from. A field added to
    /// tool/signals.json but not here would be silently unstorable.
    func testEveryUserScopedSignalIsKnownHere() {
        let catalogued = SignalCatalogue.keys(for: .user)
            .subtracting([DeeplinklyUserData.keyUserId])
        XCTAssertEqual(catalogued, DeeplinklyUserData.keys)
    }
}
