import XCTest

@testable import Deeplinkly

/// The resolve path end to end: URL in, `onDeepLink` out.
///
/// Untestable until the delivery funnel took a listener protocol and
/// `NetworkUtils.session` became injectable. Between them, every branch below
/// is now reachable without a channel, an engine, or a packet.
final class DeepLinkHandlerTests: XCTestCase {

    private var listener: RecordingDeepLinkListener!

    private let linkDomain = DeeplinklyTestSupport.configuredDomain

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        StubURLProtocol.install()
        // The paths a resolve fans out to. Individual tests override /resolve.
        StubURLProtocol.stub(DomainConfig.enrich, .ok())
        StubURLProtocol.stub(DomainConfig.sdkError, .ok())

        listener = RecordingDeepLinkListener()
        SdkRuntime.setListener(listener)
    }

    override func tearDown() {
        // Let in-flight work finish while its stubs are still installed. A
        // failing resolve reports itself asynchronously, and an error report
        // that lands after teardown would enqueue a retry into whichever test
        // is running by then.
        settle(0.2)
        StubURLProtocol.uninstall()
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("bad test URL: \(string)")
        }
        return url
    }

    /// A link on the host app's configured domain, carrying a click id.
    private func linkURL(clickId: String = "c1", extra: String = "") -> URL {
        url("https://\(linkDomain)/?click_id=\(clickId)\(extra)")
    }

    private func waitUntil(
        _ description: String, _ condition: () -> Bool, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }

    private func settle(_ interval: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    }

    // MARK: - What counts as a link

    /// A URL with neither a click id nor a readable code is not ours: no
    /// resolve, no queue entry, no delivery.
    func testAUrlWithNoIdentityIsIgnoredEntirely() {
        DeepLinkHandler.handle(url: url("https://\(linkDomain)/"), apiKey: "test-key")

        settle()
        XCTAssertEqual(listener.count, 0)
        XCTAssertTrue(DeepLinkQueue.all().isEmpty)
        StubURLProtocol.assertNoRequest(to: DomainConfig.resolveClick, settle: 0)
    }

    /// The bug `carriesShortCode` fixed: a custom-scheme in-app route was read
    /// as a code, resolved, 404'd, and the failure branch delivered a fallback
    /// — so opening a settings screen fired `onDeepLink`.
    func testACustomSchemeRouteIsNotResolvedAsACode() {
        DeepLinkHandler.handle(url: url("myapp://settings/notifications"), apiKey: "test-key")

        settle()
        XCTAssertEqual(listener.count, 0)
        StubURLProtocol.assertNoRequest(to: DomainConfig.resolveClick, settle: 0)
    }

    /// A custom scheme *with* a click id is ours — that is the shape of the
    /// fallback the backend builds.
    func testACustomSchemeWithAClickIdIsResolved() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c1", "params": [:]]))

        DeepLinkHandler.handle(url: url("myapp://open?click_id=c1"), apiKey: "test-key")

        waitUntil("delivery") { self.listener.count == 1 }
    }

    /// The Universal Link bypass: the OS routed `https://<domain>/<code>`
    /// straight to the app, so the backend never saw the click.
    func testAShortCodeOnALinkDomainIsResolved() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c9", "params": [:]]))

        DeepLinkHandler.handle(url: url("https://\(linkDomain)/abc123"), apiKey: "test-key")

        let request = StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick).first
        XCTAssertEqual(request?.body?["code"] as? String, "abc123")
        XCTAssertNil(request?.body?["click_id"])
    }

    // MARK: - The success path

    func testAResolvedLinkIsDeliveredAsTheEnvelope() {
        StubURLProtocol.stub(
            DomainConfig.resolveClick,
            .ok([
                "click_id": "c1",
                "params": ["utm_source": "news", "screen": "profile"],
            ]))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        waitUntil("delivery") { self.listener.count == 1 }
        let payload = listener.received.first
        XCTAssertEqual(payload?["click_id"] as? String, "c1")
        XCTAssertEqual(
            (payload?["params"] as? [String: Any])?["utm_source"] as? String, "news")
    }

    /// The queue entry is dropped only once the link has really been received.
    func testTheQueueEntryIsDroppedAfterDelivery() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c1", "params": [:]]))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        waitUntil("queue drained") { DeepLinkQueue.all().isEmpty }
    }

    /// Queued *before* the resolve starts, so a link whose resolve never
    /// completes is retried on the next launch.
    func testTheLinkIsQueuedBeforeTheResolveCompletes() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .offline)

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        waitUntil("queued") { DeepLinkQueue.all().count == 1 }
        XCTAssertEqual(DeepLinkQueue.all().first?.clickId, "c1")
    }

    func testFirstTouchAttributionIsPersisted() {
        StubURLProtocol.stub(
            DomainConfig.resolveClick,
            .ok(["click_id": "c1", "params": ["utm_source": "news", "gclid": "g1"]]))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        waitUntil("attribution stored") { !AttributionStore.get().isEmpty }
        let stored = AttributionStore.get()
        XCTAssertEqual(stored["click_id"] as? String, "c1")
        XCTAssertEqual(stored["utm_source"] as? String, "news")
        XCTAssertEqual(stored["source"] as? String, "deep_link")
    }

    /// The source travels with the link all the way to the backend — without it
    /// a deferred iOS install is filed as an install_referrer, which is not a
    /// thing on this platform.
    func testTheSourceIsCarriedIntoAttribution() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c1", "params": [:]]))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key", source: "clipboard")

        waitUntil("attribution stored") { !AttributionStore.get().isEmpty }
        XCTAssertEqual(AttributionStore.get()["source"] as? String, "clipboard")
    }

    // MARK: - Stale responses

    /// An unknown click id comes back 200 with `stale: true`. Delivering it
    /// would fire a deep link carrying no params at all, on every cold start
    /// until the cached id was cleared.
    func testAStaleResolveIsNotDelivered() {
        StubURLProtocol.stub(
            DomainConfig.resolveClick, .ok(["click_id": NSNull(), "params": [:], "stale": true]))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick)
        settle()
        XCTAssertEqual(listener.count, 0, "a stale click was delivered")
    }

    /// It is also not retried — a click id the backend does not know will not
    /// become known.
    func testAStaleResolveDropsTheQueueEntry() {
        StubURLProtocol.stub(
            DomainConfig.resolveClick, .ok(["click_id": NSNull(), "params": [:], "stale": true]))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        waitUntil("queue drained") { DeepLinkQueue.all().isEmpty }
    }

    // MARK: - Failure: fallback vs retry

    /// "A fallback delivery and a queued retry are alternatives, not
    /// companions" — doing both delivers the link twice for one tap.
    func testATransientFailureLeavesTheLinkQueuedAndDeliversNothing() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .offline)

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        waitUntil("failure recorded") { DeepLinkQueue.all().first?.attemptCount == 1 }
        settle()
        XCTAssertEqual(listener.count, 0, "a fallback was delivered while a retry was still owed")
        XCTAssertEqual(DeepLinkQueue.all().count, 1)
    }

    /// A revoked key or suspended account will not start working next launch,
    /// so this is the last word: deliver what the link itself carried.
    func testATerminalFailureDeliversTheFallbackImmediately() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .terminal(403))

        DeepLinkHandler.handle(
            url: linkURL(extra: "&utm_source=news&screen=profile"), apiKey: "test-key")

        waitUntil("fallback delivered") { self.listener.count == 1 }
        let payload = listener.received.first
        XCTAssertEqual(payload?["click_id"] as? String, "c1")

        // The whole query set, not just the attribution subset: this is the one
        // path where the app has no other copy of what the link addressed.
        let params = payload?["params"] as? [String: Any]
        XCTAssertEqual(params?["utm_source"] as? String, "news")
        XCTAssertEqual(params?["screen"] as? String, "profile")
        // click_id is the envelope's own key; repeating it inside params would
        // have Dart read the same value from two places.
        XCTAssertNil(params?["click_id"])
    }

    func testATerminalFailureDropsTheQueueEntry() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .terminal(403))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        waitUntil("queue drained") { DeepLinkQueue.all().isEmpty }
    }

    /// Only once the retry budget is exhausted does the transient path give up
    /// and deliver a fallback.
    ///
    /// The budget is spent directly rather than by driving five real resolves
    /// through `handle`. The guard releases its in-flight claim in a `defer`,
    /// which runs just *after* the attempt is recorded — so a loop that waits
    /// on the attempt count and immediately calls `handle` again sometimes
    /// arrives while the claim is still held and is refused. That race is a
    /// property of the test, not of the code, and it made this flaky roughly
    /// two runs in three.
    func testTheFallbackArrivesOnlyWhenTheRetryBudgetIsSpent() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .offline)

        let pending = DeepLinkQueue.PendingResolve(
            clickId: "c1", code: nil, uri: linkURL().absoluteString, source: "deep_link")
        DeepLinkQueue.enqueue(pending)
        for attempt in 1..<DeepLinkQueue.maxAttempts {
            XCTAssertTrue(
                DeepLinkQueue.recordFailure(pending), "budget ran out on attempt \(attempt)")
        }
        XCTAssertEqual(
            DeepLinkQueue.all().first?.attemptCount, DeepLinkQueue.maxAttempts - 1,
            "expected exactly one attempt left")

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        waitUntil("fallback delivered") { self.listener.count == 1 }
        XCTAssertTrue(DeepLinkQueue.all().isEmpty, "the exhausted entry was left queued")
    }

    /// The complementary half, kept separate so neither depends on timing: with
    /// budget remaining, the same failure delivers nothing.
    func testAnArrivalWithBudgetRemainingDeliversNothing() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .offline)

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        waitUntil("attempt recorded") { DeepLinkQueue.all().first?.attemptCount == 1 }
        settle()
        XCTAssertEqual(listener.count, 0)
    }

    /// A failed resolve is reported, so a systematically broken integration is
    /// visible rather than silent.
    func testAFailedResolveIsReported() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .terminal(403))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        StubURLProtocol.waitForRequest(to: DomainConfig.sdkError)
    }

    // MARK: - In-process retry

    /// Matches Android's `resolveClickWithRetry(maxRetries = 2)`: three attempts
    /// in-process before the failure branch is entered at all.
    func testATransientFailureIsRetriedThreeTimesInProcess() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .transient(503))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick, count: 3)
        settle()
        XCTAssertEqual(
            StubURLProtocol.requests(to: DomainConfig.resolveClick).count, 3,
            "the in-process retry budget changed")
    }

    /// A rejection is not retried in-process — it would fail identically three
    /// times and delay the fallback for nothing.
    func testATerminalFailureIsNotRetriedInProcess() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .terminal(403))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")

        waitUntil("fallback delivered") { self.listener.count == 1 }
        XCTAssertEqual(StubURLProtocol.requests(to: DomainConfig.resolveClick).count, 1)
    }

    // MARK: - Duplicate arrivals

    /// One tap, two arrivals, one `onDeepLink`. Dart does not dedupe — the
    /// method channel handler forwards straight to a broadcast stream.
    func testASecondArrivalAfterDeliveryIsSuppressed() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c1", "params": [:]]))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")
        waitUntil("first delivery") { self.listener.count == 1 }

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")
        settle()

        XCTAssertEqual(listener.count, 1, "one tap produced two onDeepLink calls")
    }

    /// Concurrent arrivals — the application- and scene-delegate paths both
    /// firing — resolve once between them.
    func testConcurrentArrivalsResolveOnce() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c1", "params": [:]]))

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            DeepLinkHandler.handle(url: self.linkURL(), apiKey: "test-key")
        }

        waitUntil("delivery") { self.listener.count >= 1 }
        settle()
        XCTAssertEqual(listener.count, 1)
        XCTAssertEqual(StubURLProtocol.requests(to: DomainConfig.resolveClick).count, 1)
    }

    /// Two genuinely different links are not confused for one another.
    func testDistinctLinksAreBothDelivered() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["params": [:]]))

        DeepLinkHandler.handle(url: linkURL(clickId: "c1"), apiKey: "test-key")
        DeepLinkHandler.handle(url: linkURL(clickId: "c2"), apiKey: "test-key")

        waitUntil("both delivered") { self.listener.count == 2 }
        XCTAssertEqual(Set(listener.clickIds.compactMap { $0 }), ["c1", "c2"])
    }

    // MARK: - Buffering

    /// The reason the funnel buffers: a link resolved before Dart attached must
    /// still arrive, not vanish.
    func testALinkResolvedBeforeAnyListenerAttachesIsBuffered() {
        SdkRuntime.clearListener()
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c1", "params": [:]]))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")
        StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick)
        settle()

        let late = RecordingDeepLinkListener()
        SdkRuntime.setListener(late)
        XCTAssertEqual(late.clickIds, ["c1"])
    }

    /// And its queue entry survives until then, so being killed while it sits
    /// in the buffer does not lose it.
    func testABufferedLinkKeepsItsQueueEntryUntilDelivered() {
        SdkRuntime.clearListener()
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c1", "params": [:]]))

        DeepLinkHandler.handle(url: linkURL(), apiKey: "test-key")
        StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick)
        settle()
        XCTAssertEqual(DeepLinkQueue.all().count, 1, "the entry was dropped while only buffered")

        SdkRuntime.setListener(RecordingDeepLinkListener())
        waitUntil("queue drained") { DeepLinkQueue.all().isEmpty }
    }

    // MARK: - drainPendingResolves

    /// The offline-first-launch case that matters: the pasteboard copy is gone,
    /// so the queue is the only record.
    func testDrainResolvesAQueuedLink() {
        DeepLinkQueue.enqueue(
            DeepLinkQueue.PendingResolve(
                clickId: "c1", code: nil, uri: linkURL().absoluteString, source: "clipboard"))
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c1", "params": [:]]))

        DeepLinkHandler.drainPendingResolves(apiKey: "test-key")

        waitUntil("delivery") { self.listener.count == 1 }
        waitUntil("queue drained") { DeepLinkQueue.all().isEmpty }
    }

    /// The source is preserved across the relaunch, so the backend still learns
    /// which mechanism recovered the install.
    func testDrainPreservesTheOriginalSource() {
        DeepLinkQueue.enqueue(
            DeepLinkQueue.PendingResolve(
                clickId: "c1", code: nil, uri: linkURL().absoluteString,
                source: "paste_control"))
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c1", "params": [:]]))

        DeepLinkHandler.drainPendingResolves(apiKey: "test-key")

        waitUntil("attribution stored") { !AttributionStore.get().isEmpty }
        XCTAssertEqual(AttributionStore.get()["source"] as? String, "paste_control")
    }

    /// An entry whose URI cannot be parsed is dropped rather than retried
    /// forever.
    func testDrainDiscardsAnUnparseableEntry() {
        DeepLinkQueue.enqueue(
            DeepLinkQueue.PendingResolve(
                clickId: "c1", code: nil, uri: "", source: "clipboard"))

        DeepLinkHandler.drainPendingResolves(apiKey: "test-key")

        waitUntil("entry discarded") { DeepLinkQueue.all().isEmpty }
    }

    func testDrainOnAnEmptyQueueDoesNothing() {
        DeepLinkHandler.drainPendingResolves(apiKey: "test-key")

        settle()
        XCTAssertEqual(listener.count, 0)
        StubURLProtocol.assertNoRequest(to: DomainConfig.resolveClick, settle: 0)
    }
}
