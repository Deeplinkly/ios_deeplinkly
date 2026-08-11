import XCTest

@testable import Deeplinkly

/// Cross-checks the collectors against the catalogue.
///
/// `SignalCatalogue.allows` is fail-closed, so a signal a collector emits but
/// nobody catalogued is dropped **silently, at every level including full** —
/// no error, no log, just a field that never reaches the backend. Nothing else
/// in the suite would notice; these tests are the thing that would.
///
/// The reverse direction matters too: a catalogued key nothing emits is dead
/// weight that has to stay in lockstep with Kotlin and the backend for nothing.
final class SignalCoverageTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    /// Keys assembled by `EnrichmentSender` and `DeepLinkHandler` rather than
    /// by either collector, so they appear in no collector's output.
    private let assembledElsewhere: Set<String> = [
        // EnrichmentSender
        "custom_user_id", "collected_at", "attribution_level",
        // DeepLinkHandler's attribution map
        "source", "click_id", "code", "ios_reported_at",
        // NetworkUtils.attributionQuery, off the link's own query string
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "gclid", "fbclid", "ttclid",
    ]

    /// Signals that are legitimately absent on a simulator or on a device that
    /// has not opted in, so they cannot be required to appear.
    private let notAlwaysCollected: Set<String> = [
        // Requires DeeplinklyEnableIDFA plus an authorized ATT status.
        "idfa",
        // Nil when there is no vendor identifier.
        "idfv",
        // Best-effort: absent with no network, and bounded at 500ms.
        "local_ip", "connection_type",
        // Primed asynchronously on the main thread at plugin bootstrap, which
        // does not run in a unit test.
        "webview_user_agent",
        // sysctl reads that can return nil.
        "os_build_id", "cpu_type", "device_model",
        // Reads a file creation date, which can fail.
        "installed_at",
        // Latched from a value that may itself be nil.
        "first_app_version",
    ]

    // MARK: - Nothing is emitted that would be dropped

    func testEveryStaticProfileKeyIsCatalogued() {
        assertAllCatalogued(DeviceProfile.current(), from: "DeviceProfile")
    }

    func testEveryDynamicSignalKeyIsCatalogued() {
        assertAllCatalogued(DynamicSignals.collect(), from: "DynamicSignals")
    }

    /// The assembled payload as `EnrichmentSender` builds it — profile, then
    /// dynamic sample, then the caller's attribution. If the union survives
    /// `.full` intact, nothing is being dropped on the way out.
    func testTheAssembledPayloadSurvivesFullIntact() {
        let profile = DeviceProfile.current()
        var payload: [String: String] = profile
        for (key, value) in DynamicSignals.collect(staticProfile: profile) {
            payload[key] = value
        }
        payload["custom_user_id"] = "user-1"
        payload["collected_at"] = "2026-08-11T00:00:00Z"
        payload["attribution_level"] = "full"
        payload["source"] = "deep_link"
        payload["click_id"] = "c1"

        let filtered = AttributionLevel.full.filter(payload)
        XCTAssertEqual(
            Set(payload.keys).subtracting(filtered.keys), [],
            "these keys are assembled but silently dropped by the catalogue")
    }

    // MARK: - Nothing is catalogued that nobody emits

    /// A catalogued key with no producer is dead weight kept in lockstep across
    /// three codebases for nothing. Anything genuinely produced elsewhere is
    /// listed in `assembledElsewhere` above, which doubles as the inventory of
    /// where each signal comes from.
    func testEveryCataloguedKeyHasAProducer() {
        let profile = DeviceProfile.current()
        var produced = Set(profile.keys)
        produced.formUnion(DynamicSignals.collect(staticProfile: profile).keys)
        produced.formUnion(assembledElsewhere)
        produced.formUnion(notAlwaysCollected)

        let orphaned = Set(SignalCatalogue.specs.keys).subtracting(produced)
        XCTAssertEqual(orphaned, [], "catalogued signals that nothing produces")
    }

    // MARK: - Scope matches where a signal actually comes from

    /// A signal classified `staticProfile` but collected dynamically would be
    /// cached and replayed stale; one classified `dynamicSignal` but collected
    /// statically would be re-read on every send for no reason. The
    /// classification and the collector have to agree.
    func testStaticScopedSignalsComeFromTheStaticProfile() {
        let profile = DeviceProfile.current()
        let expected = SignalCatalogue.keys(for: .staticProfile)
            .subtracting(notAlwaysCollected)

        XCTAssertEqual(
            expected.subtracting(profile.keys), [],
            "classified staticProfile but not produced by DeviceProfile")
    }

    func testDynamicScopedSignalsComeFromTheDynamicCollector() {
        let signals = DynamicSignals.collect()
        let expected = SignalCatalogue.keys(for: .dynamicSignal)
            .subtracting(notAlwaysCollected)
            .subtracting(assembledElsewhere)

        XCTAssertEqual(
            expected.subtracting(signals.keys), [],
            "classified dynamicSignal but not produced by DynamicSignals")
    }

    /// The two collectors must not both claim a key — the merge in
    /// `EnrichmentSender` lets the dynamic half win, so an overlap would mean
    /// one collector's value silently never ships.
    func testTheCollectorsDoNotOverlap() {
        let profile = DeviceProfile.current()
        let overlap = Set(profile.keys).intersection(DynamicSignals.collect().keys)
        XCTAssertEqual(overlap, [], "a key is produced by both collectors")
    }

    private func assertAllCatalogued(
        _ payload: [String: String], from source: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let uncatalogued = payload.keys.filter { SignalCatalogue.specs[$0] == nil }
        XCTAssertEqual(
            Set(uncatalogued), [],
            "\(source) emits signals absent from tool/signals.json; they are silently dropped",
            file: file, line: line)
    }
}
