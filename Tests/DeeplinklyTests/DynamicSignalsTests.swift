import XCTest

@testable import Deeplinkly

/// The signals collected fresh at send time.
///
/// Never cached and never persisted in a queue: `DeepLinkQueue` can hold a
/// pending resolve for days, and replaying a snapshot of the ATT status, the
/// network or the clock from whenever the link was first opened would report
/// stale device state as current.
final class DynamicSignalsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    // MARK: - Contents

    func testCollectCarriesConsentLocaleAndEnvironment() {
        let signals = DynamicSignals.collect()

        for key in [
            "att_status", "limit_ad_tracking", "unidentified_device",
            "locale", "language", "region", "timezone", "timezone_offset_min",
            "last_opened_at", "session_id", "ui_mode_night",
        ] {
            XCTAssertNotNil(signals[key], "\(key) missing from the dynamic sample")
        }
    }

    /// Whether the user has been asked, and what they said, is the context that
    /// explains everything else in the payload — so it is always reported.
    func testAttStatusIsAlwaysOneOfTheKnownValues() {
        let known = [
            "authorized", "denied", "restricted", "not_determined", "unknown", "not_supported",
        ]
        XCTAssertTrue(known.contains(DynamicSignals.attStatus()))
        XCTAssertTrue(known.contains(DynamicSignals.collect()["att_status"] ?? ""))
    }

    /// `limit_ad_tracking` is the inverse of an authorized status, and nothing
    /// else — a denied, restricted or unasked user all count as limited.
    func testLimitAdTrackingIsDerivedFromTheAttStatus() {
        let signals = DynamicSignals.collect()
        let authorized = signals["att_status"] == "authorized"
        XCTAssertEqual(signals["limit_ad_tracking"], String(!authorized))
    }

    /// Off by default, and deliberately a build-time switch: collecting the
    /// IDFA makes the containing app's privacy report declare tracking, which
    /// Apple requires an ATT prompt to justify. That is the app's decision to
    /// document, not ours to make by shipping a default.
    func testIdfaIsOffUnlessTheHostAppOptsIn() {
        XCTAssertFalse(
            DynamicSignals.idfaEnabled,
            "the test host opted into IDFA collection; this fixture assumes it has not")
        XCTAssertNil(
            DynamicSignals.collect()["idfa"],
            "an IDFA was collected without the host app opting in")
    }

    /// True when we hold no durable identifier for this device at all — a
    /// data-quality fact the backend would otherwise have to infer from the
    /// absence of keys it cannot tell apart from a level downgrade.
    func testUnidentifiedDeviceReflectsAnAbsentIdfv() {
        XCTAssertEqual(
            DynamicSignals.collect(staticProfile: ["idfv": "ABC-123"])["unidentified_device"],
            "false")
        XCTAssertEqual(
            DynamicSignals.collect(staticProfile: [:])["unidentified_device"], "true")
        XCTAssertEqual(
            DynamicSignals.collect(staticProfile: ["idfv": ""])["unidentified_device"], "true")
    }

    /// The one thing the static profile is consulted for. Everything else in
    /// the sample is read from the device, so an empty profile must not change
    /// the rest.
    func testStaticProfileOnlyInfluencesUnidentifiedDevice() {
        let withProfile = DynamicSignals.collect(staticProfile: ["idfv": "ABC-123"])
        let without = DynamicSignals.collect(staticProfile: [:])

        XCTAssertNotEqual(withProfile["unidentified_device"], without["unidentified_device"])
        XCTAssertEqual(withProfile["locale"], without["locale"])
        XCTAssertEqual(withProfile["timezone"], without["timezone"])
        XCTAssertEqual(withProfile["att_status"], without["att_status"])
    }

    func testBooleanSignalsAreStringifiedConsistently() {
        let signals = DynamicSignals.collect()
        for key in ["limit_ad_tracking", "unidentified_device", "ui_mode_night"] {
            XCTAssertTrue(
                ["true", "false"].contains(signals[key] ?? ""),
                "\(key) is not a stringified bool: \(signals[key] ?? "nil")")
        }
    }

    func testTimezoneOffsetIsAnInteger() {
        let offset = DynamicSignals.collect()["timezone_offset_min"]
        XCTAssertNotNil(offset)
        XCTAssertNotNil(Int(offset ?? ""), "timezone_offset_min is not numeric: \(offset ?? "nil")")
    }

    func testConnectionTypeIsOneOfTheKnownValues() {
        // Absent is legitimate: the probe is bounded at 500ms and a missing
        // connection_type is worth far less than a delayed send.
        if let connection = DynamicSignals.collect()["connection_type"] {
            XCTAssertTrue(
                ["wifi", "cellular", "ethernet", "other", "none"].contains(connection),
                "unexpected connection_type: \(connection)")
        }
    }

    /// The timestamps are the SDK's own ISO-8601 shape — UTC, second
    /// precision, `Z`-suffixed — and the backend parses them.
    func testTimestampsAreUtcIso8601() {
        let stamp = DynamicSignals.collect()["last_opened_at"] ?? ""
        let pattern = "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$"
        XCTAssertNotNil(
            stamp.range(of: pattern, options: .regularExpression),
            "last_opened_at is not UTC ISO-8601: \(stamp)")
    }

    /// Stamped on every event too, so a sample and the events from one visit
    /// can be joined server-side.
    func testSessionIdMatchesTheCurrentSession() {
        let collected = DynamicSignals.collect()["session_id"]
        XCTAssertEqual(collected, SessionManager.currentSessionId())
    }

    // MARK: - Freshness

    /// The whole reason these are not cached: two samples taken either side of
    /// a change must differ.
    func testASecondSampleIsCollectedAfresh() {
        let first = DynamicSignals.collect()
        DeeplinklyTestSupport.reset()
        let second = DynamicSignals.collect()

        XCTAssertNotEqual(
            first["session_id"], second["session_id"],
            "the sample was served from a cache across a session reset")
    }
}
