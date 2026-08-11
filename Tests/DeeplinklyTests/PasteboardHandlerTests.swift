import XCTest

@testable import Deeplinkly

/// The opt-in and priming surface of the deferred deep link path.
///
/// The read paths (`check`, `read`, `readURLString`) are not covered: they go
/// through `UIPasteboard.general`, whose contents a unit test cannot dependably
/// control. Splitting parse-and-validate from the act of reading is what would
/// unlock them — see `SEAM_TESTS.md`.
final class PasteboardHandlerTests: XCTestCase {

    private let optInKey = "deeplinkly_check_pasteboard_on_install"
    private let checkedKey = "deeplinkly_pasteboard_checked"

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        // Proves the no-read paths issue no request, rather than reasoning it.
        StubURLProtocol.install()
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    // MARK: - Opt-in

    /// On by default, on every supported iOS version. Deferred deep linking is
    /// the reason most apps integrate the SDK and the pasteboard is the only
    /// mechanism iOS offers — off by default meant it silently did not work for
    /// anyone who had not read the right doc page.
    func testTheAutomaticReadIsOnByDefault() {
        XCTAssertTrue(PasteboardHandler.isCheckEnabled())
    }

    /// The runtime override wins over the Info.plist default in both
    /// directions, so an app can turn it off and back on.
    func testTheRuntimeOverrideWinsBothWays() {
        PasteboardHandler.setCheckEnabled(false, runCheckNow: false)
        XCTAssertFalse(PasteboardHandler.isCheckEnabled())

        PasteboardHandler.setCheckEnabled(true, runCheckNow: false)
        XCTAssertTrue(PasteboardHandler.isCheckEnabled())
    }

    func testTheOverrideIsPersisted() {
        PasteboardHandler.setCheckEnabled(false, runCheckNow: false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: optInKey) as? Bool, false)
    }

    /// `runCheckNow` defaults to true precisely because bootstrap runs during
    /// plugin registration, before Dart can call anything — but enabling
    /// without an API key has nothing to resolve against and must not try.
    func testEnablingWithoutAnApiKeyRunsNoCheck() {
        PasteboardHandler.setCheckEnabled(true, apiKey: nil, runCheckNow: true)
        XCTAssertTrue(PasteboardHandler.isCheckEnabled())
        XCTAssertFalse(
            Prefs.bool(for: checkedKey),
            "a read was attempted with no API key to resolve against")
        StubURLProtocol.assertNoRequest(to: DomainConfig.resolveClick)
    }

    // MARK: - willShowBanner

    /// Lets a host app put up a priming screen before the system prompt instead
    /// of the prompt arriving unexplained. It reads no content and shows no
    /// banner itself — every path below answers without touching the
    /// pasteboard's contents.
    func testNoBannerWhenTheReadIsDisabled() {
        PasteboardHandler.setCheckEnabled(false, runCheckNow: false)
        XCTAssertFalse(willShowBanner())
    }

    /// Deferred linking is a first-launch concern; reading again would show the
    /// banner every launch and re-deliver a link already handled.
    func testNoBannerOnceTheInstallHasBeenChecked() {
        Prefs.set(true, for: checkedKey)
        XCTAssertFalse(willShowBanner())
    }

    func testNoBannerWhileTrackingIsDisabled() {
        TrackingPreferences.setTrackingDisabled(true)
        XCTAssertFalse(willShowBanner())
    }

    /// The suppressing conditions are checked before the probe, so they hold
    /// whatever is on the pasteboard.
    func testSuppressionHoldsRegardlessOfPasteboardContents() {
        Prefs.set(true, for: checkedKey)
        TrackingPreferences.setTrackingDisabled(true)
        PasteboardHandler.setCheckEnabled(false, runCheckNow: false)
        XCTAssertFalse(willShowBanner())
    }

    /// With nothing suppressing it the answer comes from the banner-free probe
    /// and depends on the simulator's pasteboard, so only its contract is
    /// asserted: it answers, once, on the main queue. Both callers go on to
    /// touch UIKit, so the queue is part of the contract.
    func testTheProbeAnswersOnceOnTheMainQueue() {
        let answered = expectation(description: "willShowBanner answered")
        var callbacks = 0
        var onMainQueue = false

        PasteboardHandler.willShowBanner { _ in
            callbacks += 1
            onMainQueue = Thread.isMainThread
            answered.fulfill()
        }

        wait(for: [answered], timeout: 5)
        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(onMainQueue, "the probe answered off the main queue")
    }

    private func willShowBanner() -> Bool {
        let answered = expectation(description: "willShowBanner answered")
        var result: Bool?
        PasteboardHandler.willShowBanner {
            result = $0
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        return result ?? true
    }
}

/// Linking a login to the install.
final class UserIdManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        StubURLProtocol.install()
        StubURLProtocol.stub(DomainConfig.enrich, .ok())
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    func testANewIdIsPersisted() {
        UserIdManager.updateCustomUserId(newId: "user-1", apiKey: "test-key")
        XCTAssertEqual(Prefs.customUserId(), "user-1")
    }

    func testTheIdCanBeChanged() {
        UserIdManager.updateCustomUserId(newId: "user-1", apiKey: "test-key")
        UserIdManager.updateCustomUserId(newId: "user-2", apiKey: "test-key")
        XCTAssertEqual(Prefs.customUserId(), "user-2")
    }

    /// Logout. The id has to actually clear, or everything after it is
    /// attributed to the previous user.
    func testTheIdCanBeCleared() {
        UserIdManager.updateCustomUserId(newId: "user-1", apiKey: "test-key")
        UserIdManager.updateCustomUserId(newId: nil, apiKey: "test-key")
        XCTAssertNil(Prefs.customUserId())
    }

    /// Linking a login has nothing to do with attribution, so it is forced
    /// past the attribution gate — a user who installed organically would
    /// otherwise never be linked at all.
    func testANewIdIsLinkedEvenWithoutAttribution() {
        UserIdManager.updateCustomUserId(newId: "user-1", apiKey: "test-key")

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.enrich).first?.body
        XCTAssertEqual(body?["custom_user_id"] as? String, "user-1")
    }

    /// `sendOnce`'s `source` parameter is used for the dedupe key and the
    /// lifecycle exemption, but is **never written into the payload** — it only
    /// reaches the backend when a caller also puts it in `attributionData`.
    ///
    /// `DeepLinkHandler` and `StartupEnrichment` do; `UserIdManager` and
    /// `AppOpenReporter` pass an empty map, so their enrichments carry no
    /// `source` at all despite `source` being a catalogued minimal-tier signal.
    /// Pinned as it behaves, and flagged: whether the backend wants a
    /// `custom_user_id` or `app_open` enrichment labelled is a product
    /// question, not one to answer by quietly changing the payload.
    func testTheSourceParameterDoesNotReachThePayload() {
        UserIdManager.updateCustomUserId(newId: "user-1", apiKey: "test-key")

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.enrich).first?.body
        XCTAssertNil(
            body?["source"],
            "sendOnce now reports its source; update the callers' expectations too")
    }

    /// Re-setting the same id is a no-op — an app that calls `setUserId` on
    /// every launch would otherwise re-link on every launch.
    func testSettingTheSameIdChangesNothing() {
        UserIdManager.updateCustomUserId(newId: "user-1", apiKey: "test-key")
        StubURLProtocol.waitForRequest(to: DomainConfig.enrich)

        UserIdManager.updateCustomUserId(newId: "user-1", apiKey: "test-key")

        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(Prefs.customUserId(), "user-1")
        XCTAssertEqual(
            StubURLProtocol.requests(to: DomainConfig.enrich).count, 1,
            "the same id was re-linked")
    }

    func testClearingAnAlreadyAbsentIdIsANoOp() {
        UserIdManager.updateCustomUserId(newId: nil, apiKey: "test-key")
        XCTAssertNil(Prefs.customUserId())
    }
}
