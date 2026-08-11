import XCTest

@testable import Deeplinkly

/// `sendEnrichment`, `logEvent`, `reportError` and `generateLink` — and the rule
/// they all share: a failure worth retrying is queued, a rejection is not.
///
/// "Queueing a request the server has already rejected outright just replays it
/// on every launch forever — a suspended account (402) or revoked key (403)
/// would never drain."
final class NetworkSendTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        StubURLProtocol.install()
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    /// Assertions are on the *type* queued rather than on the queue being
    /// empty. Other suites' asynchronous work — a failing resolve reporting
    /// itself, for instance — can land an unrelated item here after the test
    /// that started it has finished, and an `isEmpty` assertion would blame
    /// this test for it.
    private func queuedTypes() -> [String] {
        RetryQueue.items().compactMap { raw in
            guard let data = raw.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["type"] as? String
        }
    }

    // MARK: - sendEnrichment

    func testEnrichmentPostsThePayload() {
        StubURLProtocol.stub(DomainConfig.enrich, .ok())

        XCTAssertTrue(sendEnrichment(["click_id": "c1", "utm_source": "news"]))

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.enrich).first?.body
        XCTAssertEqual(body?["click_id"] as? String, "c1")
        XCTAssertEqual(body?["utm_source"] as? String, "news")
    }

    /// Nil values are compacted out rather than sent as JSON nulls.
    func testEnrichmentDropsNilValues() {
        StubURLProtocol.stub(DomainConfig.enrich, .ok())

        _ = sendEnrichment(["click_id": "c1", "utm_source": nil])

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.enrich).first?.body
        XCTAssertEqual(Set(body?.keys ?? [:].keys), ["click_id"])
    }

    func testASuccessfulEnrichmentIsNotQueued() {
        StubURLProtocol.stub(DomainConfig.enrich, .ok())

        XCTAssertTrue(sendEnrichment(["click_id": "c1"]))

        XCTAssertFalse(queuedTypes().contains("enrichment"))
    }

    /// Offline is the case the queue exists for.
    func testATransientFailureIsQueuedForRetry() {
        StubURLProtocol.stub(DomainConfig.enrich, .offline)

        XCTAssertFalse(sendEnrichment(["click_id": "c1"]))

        XCTAssertTrue(queuedTypes().contains("enrichment"))
    }

    func testA5xxIsQueuedForRetry() {
        StubURLProtocol.stub(DomainConfig.enrich, .transient(503))

        XCTAssertFalse(sendEnrichment(["click_id": "c1"]))

        XCTAssertTrue(queuedTypes().contains("enrichment"))
    }

    /// A revoked key or suspended account will not start working on the next
    /// launch, so it is dropped rather than replayed forever. The completion
    /// reports `true` — "delivered" in the sense that nothing more will happen.
    func testATerminalRejectionIsNotQueued() {
        StubURLProtocol.stub(DomainConfig.enrich, .terminal(403))

        XCTAssertTrue(
            sendEnrichment(["click_id": "c1"]),
            "a terminal rejection should report as settled, not as retryable")

        XCTAssertFalse(
            queuedTypes().contains("enrichment"), "a rejected payload was queued for retry")
    }

    func testEnrichmentIsSuppressedWhileTrackingIsDisabled() {
        StubURLProtocol.stub(DomainConfig.enrich, .ok())
        TrackingPreferences.setTrackingDisabled(true)

        XCTAssertFalse(sendEnrichment(["click_id": "c1"]))

        StubURLProtocol.assertNoRequest(to: DomainConfig.enrich)
        XCTAssertFalse(queuedTypes().contains("enrichment"))
    }

    // MARK: - logEvent

    /// The device block is a sibling of `parameters`, never inside it:
    /// `parameters` is what the tenant reads in their dashboard, and its values
    /// are truncated at 256 chars and capped at 25 keys.
    func testEventCarriesNameParametersAndASiblingDeviceBlock() {
        StubURLProtocol.stub(DomainConfig.logEvent, .ok())

        XCTAssertTrue(logEvent("purchase", ["sku": "abc"]))

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.logEvent).first?.body
        XCTAssertEqual(body?["event_name"] as? String, "purchase")
        XCTAssertEqual((body?["parameters"] as? [String: Any])?["sku"] as? String, "abc")

        let device = body?["device"] as? [String: Any]
        XCTAssertNotNil(device, "no device block on the event")
        XCTAssertNil(
            (body?["parameters"] as? [String: Any])?["platform"],
            "the device block leaked into parameters")
    }

    /// The block is filtered to the level in force, like every other payload.
    func testTheDeviceBlockHonoursTheAttributionLevel() {
        StubURLProtocol.stub(DomainConfig.logEvent, .ok())
        AttributionLevel.set(.minimal)

        _ = logEvent("purchase", [:])

        let device =
            StubURLProtocol.waitForRequest(to: DomainConfig.logEvent).first?
            .body?["device"] as? [String: Any]
        XCTAssertNotNil(device?["platform"], "a minimal-tier signal was dropped")
        XCTAssertNil(device?["screen_width"], "a full-tier signal survived level minimal")
    }

    /// Nil at level `none`, where nothing describing the device may be sent —
    /// but the event itself still goes, since level gates reporting rather than
    /// functionality.
    func testTheEventStillSendsWithoutADeviceBlockAtLevelNone() {
        StubURLProtocol.stub(DomainConfig.logEvent, .ok())
        AttributionLevel.set(.none)

        XCTAssertTrue(logEvent("purchase", [:]))

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.logEvent).first?.body
        XCTAssertEqual(body?["event_name"] as? String, "purchase")
        XCTAssertNil(body?["device"], "device state was reported at level none")
    }

    func testATransientEventFailureIsQueued() {
        StubURLProtocol.stub(DomainConfig.logEvent, .offline)

        XCTAssertFalse(logEvent("purchase", [:]))

        XCTAssertTrue(queuedTypes().contains("event"))
    }

    func testATerminalEventRejectionIsNotQueued() {
        StubURLProtocol.stub(DomainConfig.logEvent, .terminal(400))

        XCTAssertFalse(logEvent("purchase", [:]))

        XCTAssertFalse(queuedTypes().contains("event"))
    }

    func testEventsAreSuppressedWhileTrackingIsDisabled() {
        StubURLProtocol.stub(DomainConfig.logEvent, .ok())
        TrackingPreferences.setTrackingDisabled(true)

        XCTAssertFalse(logEvent("purchase", [:]))

        StubURLProtocol.assertNoRequest(to: DomainConfig.logEvent)
    }

    // MARK: - reportError

    func testErrorReportCarriesMessageAndStack() {
        StubURLProtocol.stub(DomainConfig.sdkError, .ok())

        NetworkUtils.reportError(
            apiKey: "test-key", message: "resolve exception", stack: "boom", clickId: "c1")

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.sdkError).first?.body
        XCTAssertEqual(body?["message"] as? String, "resolve exception")
        XCTAssertEqual(body?["stack"] as? String, "boom")
        XCTAssertEqual(body?["click_id"] as? String, "c1")
    }

    func testErrorReportOmitsAnAbsentClickId() {
        StubURLProtocol.stub(DomainConfig.sdkError, .ok())

        NetworkUtils.reportError(apiKey: "test-key", message: "m", stack: "s")

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.sdkError).first?.body
        XCTAssertNil(body?["click_id"])
    }

    func testATransientErrorReportIsQueued() {
        StubURLProtocol.stub(DomainConfig.sdkError, .offline)

        NetworkUtils.reportError(apiKey: "test-key", message: "m", stack: "s")
        StubURLProtocol.waitForRequest(to: DomainConfig.sdkError)

        waitUntil { self.queuedTypes().contains("error") }
        XCTAssertTrue(queuedTypes().contains("error"))
    }

    func testErrorReportsAreSuppressedWhileTrackingIsDisabled() {
        StubURLProtocol.stub(DomainConfig.sdkError, .ok())
        TrackingPreferences.setTrackingDisabled(true)

        NetworkUtils.reportError(apiKey: "test-key", message: "m", stack: "s")

        StubURLProtocol.assertNoRequest(to: DomainConfig.sdkError)
    }

    // MARK: - generateLink

    func testGenerateLinkReturnsTheUrl() {
        StubURLProtocol.stub(DomainConfig.generateLink, .ok(["url": "https://dl.example/abc"]))

        let response = generateLink(["title": "Hello"])

        XCTAssertEqual(response?["success"] as? Bool, true)
        XCTAssertEqual(response?["url"] as? String, "https://dl.example/abc")
    }

    func testGenerateLinkForwardsThePayload() {
        StubURLProtocol.stub(DomainConfig.generateLink, .ok(["url": "https://dl.example/abc"]))

        _ = generateLink(["title": "Hello", "campaign": "spring"])

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.generateLink).first?.body
        XCTAssertEqual(body?["title"] as? String, "Hello")
        XCTAssertEqual(body?["campaign"] as? String, "spring")
    }

    /// A 200 with no `url` is a failure, not a success carrying nil.
    func testGenerateLinkReportsAMissingUrl() {
        StubURLProtocol.stub(DomainConfig.generateLink, .ok(["nothing": "useful"]))

        let response = generateLink([:])

        XCTAssertEqual(response?["success"] as? Bool, false)
        XCTAssertEqual(response?["error_code"] as? String, "NO_URL")
    }

    /// Surface the backend's own ER_0xx code where there is one — "ER_011"
    /// (billing paused) is actionable, "LINK_ERROR" is not.
    func testGenerateLinkSurfacesTheBackendErrorCode() {
        StubURLProtocol.stub(
            DomainConfig.generateLink,
            .terminal(402, ["code": "ER_011", "message": "Billing paused"]))

        let response = generateLink([:])

        XCTAssertEqual(response?["success"] as? Bool, false)
        XCTAssertEqual(response?["error_code"] as? String, "ER_011")
        XCTAssertEqual(response?["error_message"] as? String, "Billing paused")
    }

    func testGenerateLinkFallsBackToTheStatusCode() {
        StubURLProtocol.stub(DomainConfig.generateLink, .terminal(404))

        let response = generateLink([:])

        XCTAssertEqual(response?["error_code"] as? String, "HTTP_404")
    }

    /// Link generation is a user-initiated action, not reporting, so it is not
    /// gated on tracking preferences and is never queued for retry.
    func testGenerateLinkFailuresAreNotQueued() {
        StubURLProtocol.stub(DomainConfig.generateLink, .offline)

        _ = generateLink([:])

        XCTAssertTrue(
            queuedTypes().allSatisfy { $0 != "link" },
            "link generation should never enqueue a retry")
    }

    // MARK: - Helpers

    private func waitUntil(
        _ condition: () -> Bool, timeout: TimeInterval = 5
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func sendEnrichment(_ payload: [String: Any?]) -> Bool {
        var delivered: Bool?
        let done = expectation(description: "enrichment")
        NetworkUtils.sendEnrichment(payload, apiKey: "test-key") {
            delivered = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return delivered ?? false
    }

    private func logEvent(_ name: String, _ parameters: [String: Any]) -> Bool {
        var ok: Bool?
        let done = expectation(description: "event")
        NetworkUtils.logEvent(
            eventName: name, parameters: parameters, apiKey: "test-key"
        ) {
            ok = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return ok ?? false
    }

    private func generateLink(_ payload: [String: Any]) -> [String: Any]? {
        var response: [String: Any]?
        let done = expectation(description: "generateLink")
        NetworkUtils.generateLink(payload: payload, apiKey: "test-key") {
            response = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return response
    }
}
