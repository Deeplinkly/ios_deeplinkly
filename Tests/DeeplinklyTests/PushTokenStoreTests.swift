import XCTest

@testable import Deeplinkly

final class PushTokenStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    func testStartsEmpty() {
        XCTAssertEqual(PushTokenStore.get(), [:])
    }

    func testStoresTheTokenAndTheProviderItAddresses() {
        XCTAssertTrue(PushTokenStore.set("tok-123", provider: .apns))

        XCTAssertEqual(
            PushTokenStore.get(),
            ["push_token": "tok-123", "push_provider": "apns"])
    }

    /// An iOS app using Firebase hands out an FCM token rather than the raw
    /// APNs one, and the prober has to know which service to speak.
    func testAnFcmTokenIsStoredAsFcmEvenOnIos() {
        PushTokenStore.set("fcm-tok", provider: .fcm)

        XCTAssertEqual(PushTokenStore.get()["push_provider"], "fcm")
    }

    /// Tokens rotate rarely and apps re-report them on every launch. Repeating
    /// one must not produce an enrichment.
    func testReportsWhetherTheStoredValueActuallyChanged() {
        XCTAssertTrue(PushTokenStore.set("tok-123", provider: .apns))
        XCTAssertFalse(PushTokenStore.set("tok-123", provider: .apns))
        XCTAssertTrue(PushTokenStore.set("tok-456", provider: .apns))
        // The provider alone changing is still a change: it decides which
        // service the prober speaks to.
        XCTAssertTrue(PushTokenStore.set("tok-456", provider: .fcm))
    }

    /// Nil means "this device has no token", which is an absence. Writing an
    /// empty string instead would reach the service as an erasure of a column
    /// that should simply stop being reported.
    func testANilTokenRemovesTheEntryRatherThanStoringABlank() {
        PushTokenStore.set("tok-123", provider: .apns)

        XCTAssertTrue(PushTokenStore.set(nil, provider: .apns))
        XCTAssertEqual(PushTokenStore.get(), [:])
        XCTAssertFalse(PushTokenStore.set(nil, provider: .apns))
    }

    func testABlankTokenIsTreatedAsARemoval() {
        PushTokenStore.set("tok-123", provider: .apns)
        PushTokenStore.set("   ", provider: .apns)

        XCTAssertEqual(PushTokenStore.get(), [:])
    }

    func testWhitespaceAroundARealTokenIsTrimmed() {
        PushTokenStore.set("  tok-123\n", provider: .apns)

        XCTAssertEqual(PushTokenStore.get()["push_token"], "tok-123")
    }

    /// Pins the length against `push_token`'s `max_len` in tool/signals.json.
    /// The generated `SignalCatalogue` carries tier and scope but not lengths,
    /// so this constant is the only thing keeping the two in step.
    func testATokenOverTheCatalogueLengthIsRefusedRatherThanTruncated() {
        let tooLong = String(repeating: "x", count: PushTokenStore.maxLength + 1)

        XCTAssertFalse(PushTokenStore.set(tooLong, provider: .apns))
        XCTAssertEqual(PushTokenStore.get(), [:])

        let atLimit = String(repeating: "x", count: PushTokenStore.maxLength)
        XCTAssertTrue(PushTokenStore.set(atLimit, provider: .apns))
    }

    func testAnEntryWrittenWithoutAProviderReadsBackAsApns() {
        PushTokenStore.set("tok-123", provider: .apns)
        Prefs.set(nil as String?, for: PushTokenStore.providerKey)

        XCTAssertEqual(PushTokenStore.get()["push_provider"], "apns")
    }

    /// The restore guard, and the reason this store has an install stamp at
    /// all. iOS restores UserDefaults onto different physical hardware, and a
    /// token that addresses the old handset either manufactures an uninstall
    /// that never happened or points the prober at someone else's phone.
    func testATokenStampedForAnotherInstallIsDropped() {
        PushTokenStore.set("tok-123", provider: .apns)
        XCTAssertEqual(PushTokenStore.get()["push_token"], "tok-123")

        // What a backup restore looks like from here: the token and its
        // provider survive, the stamp names hardware this is not.
        Prefs.set("stamp-from-the-old-phone", for: PushTokenStore.installKey)

        XCTAssertEqual(PushTokenStore.get(), [:])
        // And it is dropped rather than merely hidden, so the next read does
        // not have to re-derive the stamp to reach the same conclusion.
        XCTAssertNil(Prefs.string(for: PushTokenStore.tokenKey))
    }

    func testEveryProviderRoundTripsThroughItsWireName() {
        for provider in PushProvider.allCases {
            XCTAssertEqual(PushProvider.fromWireName(provider.wireName), provider)
        }
        XCTAssertNil(PushProvider.fromWireName("wns"))
    }

    func testAPrivacyResetRemovesTheToken() {
        PushTokenStore.set("tok-123", provider: .apns)

        _ = PrivacyData.reset()

        XCTAssertEqual(PushTokenStore.get(), [:])
    }
}
