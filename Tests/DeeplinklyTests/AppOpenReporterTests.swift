import XCTest

@testable import Deeplinkly

/// The app-open rate limit.
///
/// `TenantUser` is rewritten on every open and is the hottest write path in the
/// product, so an unthrottled ping would multiply that by the number of
/// foreground transitions per session. `shouldPing` is the whole throttle.
final class AppOpenReporterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let lastPingKey = "dl_last_open_ping_at"

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        // Not because these tests stub a response — they assert the opposite —
        // but so "no request was made" is proven rather than reasoned. Every
        // request is claimed by the stub, so nothing can reach the production
        // backend even if a guard regresses.
        StubURLProtocol.install()
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    func testFirstOpenAlwaysPings() {
        XCTAssertTrue(AppOpenReporter.shouldPing(now: now))
    }

    /// 0 means "never pinged", not "pinged at the epoch". Comparing it as a
    /// timestamp happens to work against a real wall clock only because that
    /// number is large — the check says what it means instead.
    func testAnAbsentTimestampIsNeverPingedRatherThanTheEpoch() {
        UserDefaults.standard.set(0.0, forKey: lastPingKey)
        XCTAssertTrue(AppOpenReporter.shouldPing(now: Date(timeIntervalSince1970: 0)))
    }

    func testASecondOpenInsideTheWindowIsSuppressed() {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastPingKey)
        XCTAssertFalse(AppOpenReporter.shouldPing(now: now.addingTimeInterval(60)))
        XCTAssertFalse(AppOpenReporter.shouldPing(now: now.addingTimeInterval(29 * 60)))
    }

    func testAnOpenPastTheWindowPings() {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastPingKey)
        XCTAssertTrue(
            AppOpenReporter.shouldPing(
                now: now.addingTimeInterval(SessionManager.sessionWindow + 1)))
    }

    /// Exactly at the window the ping is allowed — the interval is inclusive
    /// (`>=`), which keeps it aligned with the session boundary.
    func testTheWindowBoundaryPings() {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastPingKey)
        XCTAssertTrue(
            AppOpenReporter.shouldPing(
                now: now.addingTimeInterval(SessionManager.sessionWindow)))
    }

    /// At most one ping per session — the limit is the session window, so the
    /// two cannot drift apart.
    func testTheRateLimitTracksTheSessionWindow() {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastPingKey)
        XCTAssertFalse(
            AppOpenReporter.shouldPing(
                now: now.addingTimeInterval(SessionManager.sessionWindow - 1)))
        XCTAssertTrue(
            AppOpenReporter.shouldPing(
                now: now.addingTimeInterval(SessionManager.sessionWindow)))
    }

    /// A clock that has moved backwards — a manual time change, or an NTP
    /// correction — leaves a future timestamp behind. Pinned as current
    /// behaviour: the reporter stays silent until the clock catches up rather
    /// than pinging on every open.
    func testAFutureTimestampSuppressesUntilTheClockCatchesUp() {
        UserDefaults.standard.set(
            now.addingTimeInterval(3600).timeIntervalSince1970, forKey: lastPingKey)
        XCTAssertFalse(AppOpenReporter.shouldPing(now: now))
    }

    // MARK: - report

    /// Stops the send without stopping the stamping.
    ///
    /// `report` passes its own guards and writes the timestamp, then hands off
    /// to `EnrichmentSender`, which bails at `allowsEnrichment` before building
    /// a payload. Disabling tracking instead would short-circuit `report`
    /// itself and leave nothing under test.
    private func suppressSend() {
        AttributionLevel.set(.none)
    }

    /// Backs the reasoning above with an assertion.
    func testReportSendsNothingAtLevelNone() {
        suppressSend()
        AppOpenReporter.report(apiKey: "test-key", now: now)
        StubURLProtocol.assertNoRequest(to: DomainConfig.enrich)
    }

    /// And the tracking switch stops it before `report` even stamps.
    func testASuppressedReportSendsNothing() {
        TrackingPreferences.setTrackingDisabled(true)
        AppOpenReporter.report(apiKey: "test-key", now: now)
        StubURLProtocol.assertNoRequest(to: DomainConfig.enrich)
    }

    /// `report` records the ping before assembling anything, so the second
    /// caller inside the window is stopped by the timestamp the first wrote.
    func testReportStampsTheTimestamp() {
        suppressSend()
        AppOpenReporter.report(apiKey: "test-key", now: now)
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: lastPingKey),
            now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(AppOpenReporter.shouldPing(now: now.addingTimeInterval(60)))
    }

    /// The launch activation usually arrives while `StartupEnrichment` is also
    /// in flight; the rate limit is what makes that harmless rather than lucky.
    func testASecondReportInsideTheWindowDoesNotRestamp() {
        suppressSend()
        AppOpenReporter.report(apiKey: "test-key", now: now)
        AppOpenReporter.report(apiKey: "test-key", now: now.addingTimeInterval(60))

        XCTAssertEqual(
            UserDefaults.standard.double(forKey: lastPingKey),
            now.timeIntervalSince1970, accuracy: 0.001,
            "a suppressed report still moved the rate-limit window")
    }

    func testReportIsSuppressedWhileTrackingIsDisabled() {
        TrackingPreferences.setTrackingDisabled(true)
        AppOpenReporter.report(apiKey: "test-key", now: now)
        XCTAssertEqual(UserDefaults.standard.double(forKey: lastPingKey), 0)
    }

    /// An app that never configured a key must not report — and must not burn
    /// its rate-limit window doing nothing.
    func testReportIsSuppressedWithoutAnApiKey() {
        AppOpenReporter.report(apiKey: "", now: now)
        XCTAssertEqual(UserDefaults.standard.double(forKey: lastPingKey), 0)
    }

    func testSourceIsTheLifecycleName() {
        // `EnrichmentSender` exempts this source from its dedupe latch and its
        // attribution gate; the two have to agree on the spelling.
        XCTAssertEqual(AppOpenReporter.source, "app_open")
    }
}
