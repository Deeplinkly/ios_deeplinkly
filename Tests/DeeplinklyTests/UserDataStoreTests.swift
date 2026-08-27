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
    /// backend, as "not reported" and is skipped — so dropping the blob would
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

    /// Nothing was ever set, so there is nothing to ask the backend to erase.
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
        UserDefaults.standard.set("{not json", forKey: UserDataStore.storageKey)
        XCTAssertTrue(UserDataStore.isEmpty())
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
