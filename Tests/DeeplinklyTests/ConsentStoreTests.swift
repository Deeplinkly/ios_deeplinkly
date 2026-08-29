import XCTest

@testable import Deeplinkly

final class ConsentStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    func testStartsEmpty() {
        XCTAssertTrue(ConsentStore.isEmpty())
        XCTAssertEqual(ConsentStore.get(), [:])
    }

    /// The values are Google's, carried verbatim so the forwarder does no
    /// translation and there is no mapping table to get backwards.
    func testStoresTheWireNamesGoogleExpects() {
        ConsentStore.merge(adUserData: .granted, adPersonalization: .denied, isEEA: true)

        XCTAssertEqual(
            ConsentStore.get(),
            [
                ConsentStore.keyAdUserData: "granted",
                ConsentStore.keyAdPersonalization: "denied",
                ConsentStore.keyIsEEA: "true",
            ])
    }

    /// The documented shape of the API: an app settles the EEA question at
    /// launch and the two answers when its banner is answered, and the second
    /// call must not blank the first.
    func testMergesRatherThanReplacing() {
        ConsentStore.merge(adUserData: nil, adPersonalization: nil, isEEA: true)
        ConsentStore.merge(adUserData: .granted, adPersonalization: .granted, isEEA: nil)

        XCTAssertEqual(
            ConsentStore.get(),
            [
                ConsentStore.keyIsEEA: "true",
                ConsentStore.keyAdUserData: "granted",
                ConsentStore.keyAdPersonalization: "granted",
            ])
    }

    /// A banner re-reporting the same answer on every launch is the common
    /// case, and it must not produce an enrichment each time.
    func testReportsWhetherAnythingActuallyChanged() {
        XCTAssertTrue(ConsentStore.merge(adUserData: .granted, adPersonalization: nil, isEEA: nil))
        XCTAssertFalse(ConsentStore.merge(adUserData: .granted, adPersonalization: nil, isEEA: nil))
        XCTAssertTrue(ConsentStore.merge(adUserData: .denied, adPersonalization: nil, isEEA: nil))
    }

    func testAnAllNilCallChangesNothing() {
        XCTAssertFalse(ConsentStore.merge(adUserData: nil, adPersonalization: nil, isEEA: nil))
        XCTAssertTrue(ConsentStore.isEmpty())
    }

    /// Withdrawal is `denied`, not absence. The forwarder has to tell "this
    /// person said no" from "this app has no consent model", and deleting the
    /// record collapses the first into the second.
    func testWithdrawalIsRecordedAsAValueNotADeletion() {
        ConsentStore.merge(adUserData: .granted, adPersonalization: .granted, isEEA: nil)
        ConsentStore.merge(adUserData: .denied, adPersonalization: .denied, isEEA: nil)

        XCTAssertFalse(ConsentStore.isEmpty())
        XCTAssertEqual(ConsentStore.get()[ConsentStore.keyAdUserData], "denied")
        XCTAssertEqual(ConsentStore.get()[ConsentStore.keyAdPersonalization], "denied")
    }

    func testAnUnreadableBlobIsDiscardedRatherThanCrashingASend() {
        Prefs.set("{not json", for: ConsentStore.storageKey)

        XCTAssertEqual(ConsentStore.get(), [:])
        XCTAssertNil(Prefs.string(for: ConsentStore.storageKey))
    }

    func testEveryStateRoundTripsThroughItsWireName() {
        for state in ConsentState.allCases {
            XCTAssertEqual(ConsentState.fromWireName(state.wireName), state)
        }
        XCTAssertEqual(ConsentState.fromWireName("  GRANTED "), .granted)
        XCTAssertNil(ConsentState.fromWireName("maybe"))
        XCTAssertNil(ConsentState.fromWireName(nil))
    }

    /// The Swift and Kotlin enums must agree: the service stores one column and
    /// cannot tell which SDK wrote it.
    func testTheWireNamesMatchTheKotlinEnum() {
        XCTAssertEqual(ConsentState.granted.wireName, "granted")
        XCTAssertEqual(ConsentState.denied.wireName, "denied")
        XCTAssertEqual(ConsentState.unknown.wireName, "unknown")
    }

    /// `resetPrivacyData` is a local wipe and must leave nothing behind. The
    /// consent key is in `PrivacyData.persistedKeys` for that, which is a
    /// separate question from whether it survives a backup restore.
    func testAPrivacyResetRemovesTheConsentRecord() {
        ConsentStore.merge(adUserData: .granted, adPersonalization: .granted, isEEA: true)

        _ = PrivacyData.reset()

        XCTAssertTrue(ConsentStore.isEmpty())
    }
}
