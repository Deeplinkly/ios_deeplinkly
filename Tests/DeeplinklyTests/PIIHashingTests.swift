import XCTest

@testable import Deeplinkly

/// On-device PII hashing.
///
/// The digests here have to match the ones the service computes from
/// an erasure request, character for character, or a data subject who asks to
/// be forgotten is not found and the request reports success anyway. That is
/// why the expected values below are written out rather than computed by
/// calling the same function the code under test uses.
///
/// The Kotlin twin is `PIIHashingTest`; a case added to one belongs in the
/// other.
final class PIIHashingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PIIHashing.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PIIHashing.storageKey)
        super.tearDown()
    }

    func testIsOffUnlessTurnedOn() {
        XCTAssertFalse(PIIHashing.isEnabled())
        PIIHashing.setEnabled(true)
        XCTAssertTrue(PIIHashing.isEnabled())
        PIIHashing.setEnabled(false)
        XCTAssertFalse(PIIHashing.isEnabled())
    }

    func testOffLeavesThePayloadExactlyAsSupplied() {
        let fields = [DeeplinklyUserData.keyEmail: "Ada@Example.com"]
        XCTAssertEqual(PIIHashing.apply(fields), fields)
    }

    /// The cross-language contract. SHA-256 of "ada@example.com".
    func testEmailIsTrimmedAndLowercasedBeforeHashing() {
        XCTAssertEqual(
            PIIHashing.digest(DeeplinklyUserData.keyEmail, "  Ada@Example.com "),
            "b5fc85e55755f9e0d030a10ab4429b6b2944855f9a0d60077fe832becbc41d72")
    }

    func testPhoneKeepsOnlyDigits() {
        XCTAssertEqual(
            PIIHashing.digest(DeeplinklyUserData.keyPhone, "+44 20 7946 0000"),
            PIIHashing.digest(DeeplinklyUserData.keyPhone, "442079460000"))
    }

    func testOnlyTheFourHashableFieldsChange() {
        PIIHashing.setEnabled(true)
        let out = PIIHashing.apply([
            DeeplinklyUserData.keyEmail: "ada@example.com",
            DeeplinklyUserData.keyPhone: "442079460000",
            DeeplinklyUserData.keyFirstName: "Ada",
            DeeplinklyUserData.keyLastName: "Lovelace",
            // Not hashed: a two-value domain is enumerated in two guesses, and
            // the column could not hold a digest anyway.
            DeeplinklyUserData.keyGender: "f",
            DeeplinklyUserData.keyCountry: "GB",
            DeeplinklyUserData.keyCity: "London",
        ])
        for field in PIIHashing.hashedFields {
            XCTAssertEqual(out[field]?.count, 64, "\(field) should be a digest")
        }
        XCTAssertEqual(out[DeeplinklyUserData.keyGender], "f")
        XCTAssertEqual(out[DeeplinklyUserData.keyCountry], "GB")
        XCTAssertEqual(out[DeeplinklyUserData.keyCity], "London")
    }

    func testAnEmptyTombstoneIsNeverHashed() {
        // The one that would be catastrophic and silent. An empty string is
        // clearUserData saying "null this column"; hashing it would send a
        // digest, the service would store it as a value, and the erasure would
        // simply not have happened.
        PIIHashing.setEnabled(true)
        let out = PIIHashing.apply([
            DeeplinklyUserData.keyEmail: "",
            DeeplinklyUserData.keyPhone: "",
        ])
        XCTAssertEqual(out[DeeplinklyUserData.keyEmail], "")
        XCTAssertEqual(out[DeeplinklyUserData.keyPhone], "")
    }

    func testEveryHashedFieldCanHoldADigestInItsCatalogueLength() {
        // If a hashable field's max_len were below 64 the service would
        // truncate the digest on the way into the column, and it would match
        // nothing forever after.
        for field in PIIHashing.hashedFields {
            let limit = DeeplinklyUserData.maxLengths[field]
            XCTAssertNotNil(limit, "\(field) has no catalogue length")
            XCTAssertGreaterThanOrEqual(
                limit ?? 0, 64, "\(field) max_len cannot hold a digest")
        }
    }

    func testTheModeIsReportedToTheBackend() {
        // Without this the service cannot know the column holds a digest, and
        // the erasure matcher has nothing to branch on.
        PIIHashing.setEnabled(true)
        let profile = DeviceProfile.current()
        let signals = DynamicSignals.collect(staticProfile: profile)
        XCTAssertEqual(signals[PIIHashing.keyPIIHashingEnabled], "true")
    }
}
