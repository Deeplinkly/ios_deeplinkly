import XCTest

@testable import Deeplinkly

final class UserDataStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    func testStartsEmpty() {
        XCTAssertTrue(UserDataStore.isEmpty())
        XCTAssertEqual(UserDataStore.get(), [:])
    }

    /// The behaviour the public API is documented on: an app learns an email at
    /// sign-up and an address at checkout, and the second call must not erase
    /// the first.
    func testMergesRatherThanReplacing() {
        UserDataStore.merge([DeeplinklyUserData.keyEmail: "ada@example.com"])
        UserDataStore.merge([DeeplinklyUserData.keyCity: "London"])

        XCTAssertEqual(
            UserDataStore.get(),
            [
                DeeplinklyUserData.keyEmail: "ada@example.com",
                DeeplinklyUserData.keyCity: "London",
            ])
    }

    func testALaterValueReplacesAnEarlierOneForTheSameField() {
        UserDataStore.merge([DeeplinklyUserData.keyEmail: "old@example.com"])
        UserDataStore.merge([DeeplinklyUserData.keyEmail: "new@example.com"])
        XCTAssertEqual(UserDataStore.get()[DeeplinklyUserData.keyEmail], "new@example.com")
    }

    func testIgnoresAKeyThatIsNotAUserDataField() {
        UserDataStore.merge(["idfa": "should-not-be-here"])
        XCTAssertTrue(UserDataStore.isEmpty())
    }

    /// The whole reason clearing is not a delete. An absent key reads, at the
    /// service, as "not reported" and is skipped — so dropping the blob would
    /// leave the row on our side holding the email forever. An empty value is
    /// what says "erase this".
    func testClearingTombstonesTheFieldsThatWereSet() {
        UserDataStore.merge([
            DeeplinklyUserData.keyEmail: "ada@example.com",
            DeeplinklyUserData.keyCity: "London",
        ])
        UserDataStore.clear()

        XCTAssertEqual(
            UserDataStore.get(),
            [
                DeeplinklyUserData.keyEmail: "",
                DeeplinklyUserData.keyCity: "",
            ])
    }

    /// Nothing was ever set, so there is nothing to ask the service to erase.
    func testClearingAnEmptyStoreLeavesItEmpty() {
        UserDataStore.clear()
        XCTAssertTrue(UserDataStore.isEmpty())
    }

    /// The tombstone outlives the send that carries it. Delivery is not
    /// observable from the store, and a clear lost because the device happened
    /// to be offline is the one failure this must not have.
    func testTheTombstoneSurvivesALaterRead() {
        UserDataStore.merge([DeeplinklyUserData.keyEmail: "ada@example.com"])
        UserDataStore.clear()
        _ = UserDataStore.get()
        XCTAssertEqual(UserDataStore.get()[DeeplinklyUserData.keyEmail], "")
    }

    func testSettingAValueAfterAClearReplacesTheTombstoneForThatField() {
        UserDataStore.merge([
            DeeplinklyUserData.keyEmail: "ada@example.com",
            DeeplinklyUserData.keyCity: "London",
        ])
        UserDataStore.clear()
        UserDataStore.merge([DeeplinklyUserData.keyEmail: "grace@example.com"])

        XCTAssertEqual(UserDataStore.get()[DeeplinklyUserData.keyEmail], "grace@example.com")
        // Still erasing the one that was not re-set.
        XCTAssertEqual(UserDataStore.get()[DeeplinklyUserData.keyCity], "")
    }

    func testDiscardsABlobItCannotParse() {
        Keychain.set(
            "{not json", for: UserDataStore.storageKey,
            accessibility: Keychain.thisDeviceOnly)
        XCTAssertTrue(UserDataStore.isEmpty())
        XCTAssertNil(Keychain.get(UserDataStore.storageKey))
    }

    /// The values live in the Keychain, not the app container's plist.
    ///
    /// Asserted rather than assumed because the difference is invisible from
    /// every other test in this file — `get`/`merge`/`clear` behave identically
    /// either way, and the whole point of the move is what happens to a device
    /// backup, which no unit test can observe.
    func testIsStoredInTheKeychainAndNotInUserDefaults() {
        UserDataStore.merge([DeeplinklyUserData.keyEmail: "ada@example.com"])

        XCTAssertNotNil(Keychain.get(UserDataStore.storageKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: UserDataStore.storageKey))
    }

    /// A pre-release build wrote the blob to UserDefaults. Reading it must move
    /// it, and must leave nothing behind — an abandoned copy would be the exact
    /// plaintext this change exists to remove.
    func testMigratesAPreReleasePayloadOutOfUserDefaults() {
        UserDataStore.purge()
        UserDefaults.standard.set(
            #"{"user_email":"legacy@example.com"}"#, forKey: UserDataStore.storageKey)

        XCTAssertEqual(UserDataStore.get()[DeeplinklyUserData.keyEmail], "legacy@example.com")
        XCTAssertNil(UserDefaults.standard.string(forKey: UserDataStore.storageKey))
        XCTAssertNotNil(Keychain.get(UserDataStore.storageKey))
    }

    /// The migration must carry a tombstone too. A pending erasure dropped on
    /// the way to the keychain is an erasure the service never hears about.
    func testMigrationCarriesAPendingTombstone() {
        UserDataStore.purge()
        UserDefaults.standard.set(
            #"{"user_email":""}"#, forKey: UserDataStore.storageKey)

        XCTAssertEqual(UserDataStore.get()[DeeplinklyUserData.keyEmail], "")
        XCTAssertNil(UserDefaults.standard.string(forKey: UserDataStore.storageKey))
    }

    /// `PrivacyData.reset()` is the field-level deletion contract, and personal
    /// data is the one thing that must not survive it.
    func testPrivacyResetErasesIt() {
        UserDataStore.merge([DeeplinklyUserData.keyEmail: "ada@example.com"])
        PrivacyData.reset()
        XCTAssertTrue(UserDataStore.isEmpty())
    }
}
