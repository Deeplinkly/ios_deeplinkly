import XCTest

@testable import Deeplinkly

/// The `Deeplinkly` facade's *own* logic.
///
/// Everything it delegates to is already covered by the suites for those types,
/// and re-testing it through the facade would only pin the delegation twice.
/// What is new here, and therefore what is tested here: the initialisation
/// latch, the pre-init link buffer, the event-sequence counter, and the fact
/// that a rejected event never reaches the network.
final class DeeplinklyTests: XCTestCase {

    private let apiKey = "test-key"

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        StubURLProtocol.install()
        // Initialisation fires startup enrichment, a pasteboard check and a
        // retry drain. None of it is under test here; stubbing everything keeps
        // it from failing as unstubbed traffic.
        StubURLProtocol.stubAll(.ok())
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    // MARK: - Initialisation

    func testAKeyEnablesTheSdk() {
        Deeplinkly.initialize(apiKey: apiKey)
        XCTAssertTrue(Deeplinkly.isEnabled)
    }

    func testAnEmptyKeyLeavesTheSdkDisabled() {
        Deeplinkly.initialize(apiKey: "")
        XCTAssertFalse(Deeplinkly.isEnabled)
    }

    func testAWhitespaceOnlyKeyLeavesTheSdkDisabled() {
        Deeplinkly.initialize(apiKey: "   ")
        XCTAssertFalse(Deeplinkly.isEnabled)
    }

    /// A host that initialises from both its app delegate and the plugin's
    /// registration must not double-register anything. The observable proof is
    /// that a second call cannot change the outcome of the first.
    func testInitializeIsIdempotent() {
        Deeplinkly.initialize(apiKey: "")
        XCTAssertFalse(Deeplinkly.isEnabled)

        Deeplinkly.initialize(apiKey: apiKey)
        XCTAssertFalse(
            Deeplinkly.isEnabled,
            "the second initialize() was not ignored")
    }

    func testInitializeIsIdempotentInTheOtherDirection() {
        Deeplinkly.initialize(apiKey: apiKey)
        Deeplinkly.initialize(apiKey: "")
        XCTAssertTrue(Deeplinkly.isEnabled)
    }

    func testTheVersionIsReported() {
        XCTAssertEqual(Deeplinkly.version, SdkInfo.version)
    }

    // MARK: - Pre-init links

    /// A Universal Link can reach a host app's delegate before it has called
    /// `initialize`, and on a cold start that is the launch deferred deep
    /// linking exists for. Dropping it there loses exactly the case that
    /// matters.
    func testALinkArrivingBeforeInitIsBuffered() {
        let url = URL(string: "https://\(DeeplinklyTestSupport.configuredDomain)/x?click_id=c1")!
        Deeplinkly.handleLink(url)

        XCTAssertEqual(Deeplinkly.takePendingLink(), url)
    }

    func testThePendingLinkIsTakenOnlyOnce() {
        let url = URL(string: "https://\(DeeplinklyTestSupport.configuredDomain)/x?click_id=c1")!
        Deeplinkly.handleLink(url)

        XCTAssertNotNil(Deeplinkly.takePendingLink())
        XCTAssertNil(Deeplinkly.takePendingLink())
    }

    func testInitializeConsumesTheBufferedLink() {
        let url = URL(string: "https://\(DeeplinklyTestSupport.configuredDomain)/x?click_id=c1")!
        Deeplinkly.handleLink(url)

        Deeplinkly.initialize(apiKey: apiKey)

        XCTAssertNil(
            Deeplinkly.takePendingLink(),
            "initialize() should have flushed the buffer through the normal path")
    }

    func testALinkArrivingAfterInitIsNotBuffered() {
        Deeplinkly.initialize(apiKey: apiKey)
        let url = URL(string: "https://\(DeeplinklyTestSupport.configuredDomain)/x?click_id=c1")!

        Deeplinkly.handleLink(url)

        XCTAssertNil(Deeplinkly.takePendingLink())
    }

    /// Only the most recent one is held. A pre-init buffer is a cold-start
    /// hand-off, not a queue — `DeepLinkQueue` is what provides durability.
    func testTheBufferHoldsOnlyTheLatestLink() {
        let first = URL(string: "https://\(DeeplinklyTestSupport.configuredDomain)/a?click_id=1")!
        let second = URL(string: "https://\(DeeplinklyTestSupport.configuredDomain)/b?click_id=2")!

        Deeplinkly.handleLink(first)
        Deeplinkly.handleLink(second)

        XCTAssertEqual(Deeplinkly.takePendingLink(), second)
    }

    // MARK: - Events: validation reaches the network boundary

    func testAValidEventIsSent() {
        Deeplinkly.initialize(apiKey: apiKey)

        let answered = expectation(description: "logEvent answered")
        Deeplinkly.logEvent("purchase", parameters: ["sku": "abc"]) { ok in
            XCTAssertTrue(ok)
            answered.fulfill()
        }

        wait(for: [answered], timeout: 5)
        let sent = StubURLProtocol.requests(to: DomainConfig.logEvent)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.body?["event_name"] as? String, "purchase")
    }

    /// The point of the whole exercise: a rejected event answers false and
    /// costs nothing. Before the facade, iOS validated nothing and every one of
    /// these went to a production service.
    func testARejectedEventNeverReachesTheNetwork() {
        Deeplinkly.initialize(apiKey: apiKey)

        let answered = expectation(description: "logEvent answered")
        Deeplinkly.logEvent("e", parameters: ["_dl_event_seq": "999"]) { ok in
            XCTAssertFalse(ok)
            answered.fulfill()
        }

        wait(for: [answered], timeout: 5)
        StubURLProtocol.assertNoRequest(to: DomainConfig.logEvent)
    }

    func testAnEmptyEventNameIsRejectedWithoutANetworkCall() {
        Deeplinkly.initialize(apiKey: apiKey)

        let answered = expectation(description: "logEvent answered")
        Deeplinkly.logEvent("   ") { ok in
            XCTAssertFalse(ok)
            answered.fulfill()
        }

        wait(for: [answered], timeout: 5)
        StubURLProtocol.assertNoRequest(to: DomainConfig.logEvent)
    }

    func testTheEventNameIsSentTrimmed() {
        Deeplinkly.initialize(apiKey: apiKey)

        let answered = expectation(description: "logEvent answered")
        Deeplinkly.logEvent("  purchase  ") { _ in answered.fulfill() }
        wait(for: [answered], timeout: 5)

        let sent = StubURLProtocol.requests(to: DomainConfig.logEvent)
        XCTAssertEqual(sent.first?.body?["event_name"] as? String, "purchase")
    }

    func testADisabledSdkAnswersFalseWithoutANetworkCall() {
        Deeplinkly.initialize(apiKey: "")

        let answered = expectation(description: "logEvent answered")
        Deeplinkly.logEvent("purchase") { ok in
            XCTAssertFalse(ok)
            answered.fulfill()
        }

        wait(for: [answered], timeout: 5)
        StubURLProtocol.assertNoRequest(to: DomainConfig.logEvent)
    }

    func testCompletionsRunOnTheMainThread() {
        Deeplinkly.initialize(apiKey: apiKey)

        let answered = expectation(description: "logEvent answered")
        var onMain = false
        Deeplinkly.logEvent("purchase") { _ in
            onMain = Thread.isMainThread
            answered.fulfill()
        }

        wait(for: [answered], timeout: 5)
        XCTAssertTrue(onMain, "the completion must be safe to touch UI from")
    }

    // MARK: - Events: the sequence counter

    private func sequenceNumbers() -> [Int] {
        StubURLProtocol.requests(to: DomainConfig.logEvent)
            .compactMap { $0.body?["parameters"] as? [String: Any] }
            .compactMap { $0["_dl_event_seq"] as? String }
            .compactMap(Int.init)
    }

    func testTheSequenceStartsAtOne() {
        Deeplinkly.initialize(apiKey: apiKey)

        let answered = expectation(description: "logEvent answered")
        Deeplinkly.logEvent("first") { _ in answered.fulfill() }
        wait(for: [answered], timeout: 5)

        XCTAssertEqual(sequenceNumbers(), [1])
    }

    func testTheSequenceIncrementsPerEvent() {
        Deeplinkly.initialize(apiKey: apiKey)

        for name in ["a", "b", "c"] {
            let answered = expectation(description: name)
            Deeplinkly.logEvent(name) { _ in answered.fulfill() }
            wait(for: [answered], timeout: 5)
        }

        XCTAssertEqual(sequenceNumbers(), [1, 2, 3])
    }

    func testTheSequenceResumesFromWhatWasPersisted() {
        UserDefaults.standard.set(41, forKey: "dl_event_seq")
        Deeplinkly.initialize(apiKey: apiKey)

        let answered = expectation(description: "logEvent answered")
        Deeplinkly.logEvent("resumed") { _ in answered.fulfill() }
        wait(for: [answered], timeout: 5)

        XCTAssertEqual(sequenceNumbers(), [42])
    }

    /// The bug this replaced: a plain `UserDefaults.integer(forKey:) + 1`. Two
    /// calls landing together both read the same value and both wrote it back,
    /// so the counter that exists to *order* events handed out duplicates.
    func testConcurrentEventsGetDistinctSequenceNumbers() {
        Deeplinkly.initialize(apiKey: apiKey)

        let count = 24
        for i in 0..<count {
            DispatchQueue.global(qos: .userInitiated).async {
                Deeplinkly.logEvent("concurrent-\(i)")
            }
        }

        StubURLProtocol.waitForRequest(to: DomainConfig.logEvent, count: count, timeout: 20)

        let seqs = sequenceNumbers()
        XCTAssertEqual(seqs.count, count)
        XCTAssertEqual(
            Set(seqs).count, count,
            "duplicate sequence numbers: \(seqs.sorted())")
        XCTAssertEqual(seqs.sorted(), Array(1...count))
    }

    // MARK: - Privacy passthrough

    func testTrackingCanBeTurnedOffAndBackOn() {
        XCTAssertTrue(Deeplinkly.isTrackingEnabled())

        Deeplinkly.setTrackingEnabled(false)
        XCTAssertFalse(Deeplinkly.isTrackingEnabled())

        Deeplinkly.setTrackingEnabled(true)
        XCTAssertTrue(Deeplinkly.isTrackingEnabled())
    }

    /// Disabling tracking is absolute and outranks any level set, which is what
    /// the public Dart API documents.
    func testDisablingTrackingCollapsesTheAttributionLevel() {
        Deeplinkly.setAttributionLevel(.full)
        XCTAssertEqual(Deeplinkly.getAttributionLevel(), .full)

        Deeplinkly.setTrackingEnabled(false)
        XCTAssertEqual(Deeplinkly.getAttributionLevel(), AttributionLevel.none)
    }

    func testPrivacyResetDeletesLocalDataAndLeavesTrackingDisabled() {
        let oldId = DeviceIdManager.getOrCreate()
        Prefs.setCustomUserId("customer-1")
        UserDefaults.standard.set("{\"click_id\":\"c1\"}", forKey: "initial_attribution")
        UserDefaults.standard.set("session-1", forKey: "dl_session_id")
        UserDefaults.standard.set(true, forKey: "deep_link_enriched_click_id=c1")
        UserDefaults.standard.set(true, forKey: "host_app_enriched")
        RetryQueue.enqueue(type: "event", payload: ["event_name": "purchase"])

        XCTAssertTrue(Deeplinkly.resetPrivacyData())

        XCTAssertTrue(TrackingPreferences.isTrackingDisabled())
        XCTAssertNil(Prefs.customUserId())
        XCTAssertNil(UserDefaults.standard.object(forKey: "initial_attribution"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "dl_session_id"))
        XCTAssertNil(
            UserDefaults.standard.object(forKey: "deep_link_enriched_click_id=c1"))
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "host_app_enriched"), true)
        UserDefaults.standard.removeObject(forKey: "host_app_enriched")
        XCTAssertTrue(RetryQueue.items().isEmpty)
        XCTAssertNotEqual(oldId, DeviceIdManager.getOrCreate())
        XCTAssertTrue(TrackingPreferences.isTrackingDisabled())
    }

    func testTheAttributionLevelRoundTrips() {
        for level in AttributionLevel.allCases {
            XCTAssertTrue(Deeplinkly.setAttributionLevel(level))
            XCTAssertEqual(Deeplinkly.getAttributionLevel(), level)
        }
    }

    // MARK: - Identity

    /// Identity works with no API key, on both platforms — it is generated
    /// locally and the bridge answers `getDeeplinklyId` before its enabled
    /// check for exactly this reason.
    func testTheInstallIdWorksWhileDisabled() {
        Deeplinkly.initialize(apiKey: "")

        let id = Deeplinkly.getDeeplinklyId()
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(id, Deeplinkly.getDeeplinklyId())
    }

    func testInstallAttributionIsEmptyUntilALinkResolves() {
        Deeplinkly.initialize(apiKey: apiKey)
        XCTAssertTrue(Deeplinkly.getInstallAttribution().isEmpty)
    }

    // MARK: - Listener

    func testTheListenerReceivesDeliveries() {
        let listener = RecordingDeepLinkListener()
        // Attach, then clear. `SdkRuntime`'s buffer is process-global and
        // survives `clearListener`, so an earlier test whose resolve completed
        // with nothing listening has left an item in it — attaching flushes
        // that, and asserting before the flush would count someone else's link.
        Deeplinkly.setDeepLinkListener(listener)
        listener.reset()

        SdkRuntime.deliverDeepLink(["click_id": "facade-delivery"])

        XCTAssertEqual(listener.clickIds, ["facade-delivery"])
    }

    func testPassingNilDetachesTheListener() {
        Deeplinkly.setDeepLinkListener(RecordingDeepLinkListener())
        XCTAssertTrue(SdkRuntime.isReady())

        Deeplinkly.setDeepLinkListener(nil)
        XCTAssertFalse(SdkRuntime.isReady())
    }

    func testShutdownDetachesTheListener() {
        Deeplinkly.setDeepLinkListener(RecordingDeepLinkListener())
        Deeplinkly.shutdown()
        XCTAssertFalse(SdkRuntime.isReady())
    }
}
