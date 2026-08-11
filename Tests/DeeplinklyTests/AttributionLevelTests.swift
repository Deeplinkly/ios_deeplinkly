import XCTest

@testable import Deeplinkly

final class AttributionLevelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    // MARK: - Resolution

    /// The pre-1.9.0 behaviour, and what an app that configures nothing gets.
    /// (The test host's Info.plist sets no `DeeplinklyAttributionLevel`, so
    /// this exercises the final fallback rather than the plist branch.)
    func testDefaultsToFull() {
        XCTAssertEqual(AttributionLevel.current, .full)
    }

    func testStoredLevelIsHonoured() {
        for level in AttributionLevel.allCases {
            AttributionLevel.set(level)
            XCTAssertEqual(AttributionLevel.current, level)
        }
    }

    func testStoredLevelSurvivesAsRawString() {
        AttributionLevel.set(.reduced)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "dl_attribution_level"), "reduced")
    }

    /// A value written by a newer SDK, or corrupted, must not resolve to
    /// something more permissive by accident — it falls through to the normal
    /// default rather than throwing.
    func testUnrecognisedStoredValueFallsThrough() {
        UserDefaults.standard.set("catastrophic", forKey: "dl_attribution_level")
        XCTAssertEqual(AttributionLevel.current, .full)
    }

    /// `disableTracking` is absolute: it collapses to `.none` whatever was set,
    /// and does not overwrite the stored level, so re-enabling restores it.
    func testTrackingDisabledCollapsesToNone() {
        AttributionLevel.set(.full)
        TrackingPreferences.setTrackingDisabled(true)
        XCTAssertEqual(AttributionLevel.current, .none)

        TrackingPreferences.setTrackingDisabled(false)
        XCTAssertEqual(AttributionLevel.current, .full, "stored level was not preserved")
    }

    func testTrackingDisabledOverridesEvenAnExplicitFull() {
        TrackingPreferences.setTrackingDisabled(true)
        AttributionLevel.set(.full)
        XCTAssertEqual(AttributionLevel.current, .none)
    }

    // MARK: - allowsEnrichment

    func testOnlyNoneSuppressesEnrichment() {
        XCTAssertTrue(AttributionLevel.full.allowsEnrichment)
        XCTAssertTrue(AttributionLevel.reduced.allowsEnrichment)
        XCTAssertTrue(AttributionLevel.minimal.allowsEnrichment)
        XCTAssertFalse(AttributionLevel.none.allowsEnrichment)
    }

    // MARK: - filter

    func testFilterKeepsPermittedAndDropsTheRest() {
        let payload = [
            "click_id": "abc",  // minimal
            "utm_source": "newsletter",  // reduced
            "screen_width": "1170",  // full
        ]

        XCTAssertEqual(AttributionLevel.full.filter(payload).count, 3)
        XCTAssertEqual(
            Set(AttributionLevel.reduced.filter(payload).keys), ["click_id", "utm_source"])
        XCTAssertEqual(Set(AttributionLevel.minimal.filter(payload).keys), ["click_id"])
        XCTAssertTrue(AttributionLevel.none.filter(payload).isEmpty)
    }

    /// Fail-closed reaches the filter, not just `allows`: an uncatalogued key
    /// is dropped even at `.full`.
    func testFilterDropsUncataloguedKeysAtFull() {
        let filtered = AttributionLevel.full.filter(["surprise": "value", "click_id": "abc"])
        XCTAssertEqual(Set(filtered.keys), ["click_id"])
    }

    /// The generic signature is load-bearing: `DeviceProfile` produces
    /// `[String: String]` and `EnrichmentSender` assembles `[String: String?]`,
    /// and both are filtered by the same code.
    func testFilterWorksOverOptionalValues() {
        let payload: [String: String?] = [
            "click_id": "abc",
            "screen_width": nil,
            "utm_source": nil,
        ]
        let filtered = AttributionLevel.reduced.filter(payload)
        XCTAssertEqual(Set(filtered.keys), ["click_id", "utm_source"])
        // A permitted key with a nil value is kept as a present nil, not
        // dropped — the sender compacts those later.
        XCTAssertEqual(filtered["utm_source"], String?.none)
    }

    func testFilterOnEmptyPayloadIsEmpty() {
        XCTAssertTrue(AttributionLevel.full.filter([String: String]()).isEmpty)
    }

    /// `filter` and `allows` must agree — the filter is only ever a bulk
    /// application of the catalogue.
    func testFilterAgreesWithCatalogue() {
        let payload = SignalCatalogue.specs.keys.reduce(into: [String: String]()) {
            $0[$1] = "x"
        }
        for level in AttributionLevel.allCases {
            let filtered = Set(level.filter(payload).keys)
            let expected = Set(payload.keys.filter { SignalCatalogue.allows($0, at: level) })
            XCTAssertEqual(filtered, expected, "disagreement at \(level.rawValue)")
        }
    }

    // MARK: - Raw values

    /// The raw values are the wire format — they are stored in `UserDefaults`,
    /// read from Info.plist, and sent as `attribution_level`. The backend is
    /// production, so renaming one is a breaking change.
    func testRawValuesAreStable() {
        XCTAssertEqual(AttributionLevel.full.rawValue, "full")
        XCTAssertEqual(AttributionLevel.reduced.rawValue, "reduced")
        XCTAssertEqual(AttributionLevel.minimal.rawValue, "minimal")
        XCTAssertEqual(AttributionLevel.none.rawValue, "none")
    }

    func testAllCasesIsOrderedMostToLeastPermissive() {
        XCTAssertEqual(AttributionLevel.allCases, [.full, .reduced, .minimal, .none])
    }
}
