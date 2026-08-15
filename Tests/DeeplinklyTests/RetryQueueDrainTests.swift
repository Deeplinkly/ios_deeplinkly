import XCTest

@testable import Deeplinkly

/// `RetryQueue.retryAll` — the dispatch half, which could not be covered before
/// the session became injectable because `sendNow` blocks on a live request.
///
/// This is also where the TTL boundary finally gets tested: an item inside the
/// window falls straight through to a send, so proving it was *not* swept means
/// proving it *was* sent.
final class RetryQueueDrainTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        StubURLProtocol.install()
        StubURLProtocol.stubAll(.ok())
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    /// `retryAll` blocks on a semaphore per item, so it must not run on the
    /// thread the response is delivered to.
    private func drain() {
        let done = expectation(description: "retryAll")
        DispatchQueue.global(qos: .utility).async {
            RetryQueue.retryAll(apiKey: "test-key")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    private func store(type: String, payload: [String: Any], ageInDays: Double = 0) {
        var item: [String: Any] = ["type": type, "payload": payload]
        if ageInDays > 0 {
            item["queued_at"] = Date().timeIntervalSince1970 - (ageInDays * 24 * 60 * 60)
        } else {
            item["queued_at"] = Date().timeIntervalSince1970
        }
        guard let data = try? JSONSerialization.data(withJSONObject: item),
            let encoded = String(data: data, encoding: .utf8)
        else { return XCTFail("could not encode fixture") }

        var queue = UserDefaults.standard.array(forKey: "dl_pending_retries") as? [String] ?? []
        queue.append(encoded)
        UserDefaults.standard.set(queue, forKey: "dl_pending_retries")
    }

    // MARK: - Dispatch

    func testEachTypeGoesToItsOwnEndpoint() {
        store(type: "enrichment", payload: ["click_id": "c1"])
        store(type: "event", payload: ["event_name": "purchase"])
        store(type: "error", payload: ["message": "boom"])

        drain()

        XCTAssertEqual(StubURLProtocol.requests(to: DomainConfig.enrich).count, 1)
        XCTAssertEqual(StubURLProtocol.requests(to: DomainConfig.logEvent).count, 1)
        XCTAssertEqual(StubURLProtocol.requests(to: DomainConfig.sdkError).count, 1)
    }

    func testTheStoredPayloadIsWhatGetsSent() {
        store(type: "event", payload: ["event_name": "purchase", "parameters": ["sku": "abc"]])

        drain()

        let body = StubURLProtocol.requests(to: DomainConfig.logEvent).first?.body
        XCTAssertEqual(body?["event_name"] as? String, "purchase")
        XCTAssertEqual((body?["parameters"] as? [String: Any])?["sku"] as? String, "abc")
    }

    func testASentItemIsRemoved() {
        store(type: "enrichment", payload: ["click_id": "c1"])

        drain()

        XCTAssertTrue(RetryQueue.items().isEmpty)
    }

    func testEveryItemIsAttempted() {
        for index in 0..<5 {
            store(type: "enrichment", payload: ["click_id": "c\(index)"])
        }

        drain()

        XCTAssertEqual(StubURLProtocol.requests(to: DomainConfig.enrich).count, 5)
        XCTAssertTrue(RetryQueue.items().isEmpty)
    }

    // MARK: - Failure handling

    /// Still offline: the item stays for the next launch.
    func testATransientFailureKeepsTheItem() {
        StubURLProtocol.stub(DomainConfig.enrich, .offline)
        store(type: "enrichment", payload: ["click_id": "c1"])

        drain()

        XCTAssertEqual(RetryQueue.items().count, 1)
    }

    /// "A rejected payload never becomes valid, so keeping it means replaying
    /// it on every launch for the life of the install."
    func testATerminalRejectionDropsTheItem() {
        StubURLProtocol.stub(DomainConfig.enrich, .terminal(403))
        store(type: "enrichment", payload: ["click_id": "c1"])

        drain()

        XCTAssertTrue(RetryQueue.items().isEmpty)
    }

    /// One bad item must not block the rest of the queue.
    func testAFailingItemDoesNotStopTheOthers() {
        StubURLProtocol.stub(DomainConfig.enrich, .offline)
        store(type: "enrichment", payload: ["click_id": "c1"])
        store(type: "event", payload: ["event_name": "purchase"])

        drain()

        XCTAssertEqual(StubURLProtocol.requests(to: DomainConfig.logEvent).count, 1)
        XCTAssertEqual(RetryQueue.items().count, 1, "only the failing item should remain")
    }

    // MARK: - refilter

    /// "Retry items are stored fully assembled and already filtered, so without
    /// this a level downgrade between queueing and sending would never be
    /// honoured for anything already in the queue."
    func testEnrichmentIsRefilteredAgainstTheLevelInForceNow() {
        store(
            type: "enrichment",
            payload: ["click_id": "c1", "utm_source": "news", "screen_width": "1170"])
        AttributionLevel.set(.reduced)

        drain()

        let body = StubURLProtocol.requests(to: DomainConfig.enrich).first?.body
        XCTAssertNotNil(body?["click_id"])
        XCTAssertNotNil(body?["utm_source"])
        XCTAssertNil(
            body?["screen_width"], "a full-tier signal was replayed after a downgrade to reduced")
    }

    /// It also repairs items stored by an older SDK carrying keys this build no
    /// longer catalogues — fail-closed reaches the retry path.
    func testRefilterStripsUncataloguedKeysFromStoredItems() {
        store(type: "enrichment", payload: ["click_id": "c1", "retired_signal": "x"])

        drain()

        let body = StubURLProtocol.requests(to: DomainConfig.enrich).first?.body
        XCTAssertNil(body?["retired_signal"])
    }

    /// Event metadata is preserved while its nested device sample is filtered
    /// against the consent level in force when the retry actually leaves.
    func testEventDeviceBlockIsRefilteredWithoutStrippingTheEvent() {
        store(
            type: "event",
            payload: [
                "event_name": "purchase",
                "parameters": ["sku": "A1"],
                "device": ["deeplinkly_device_id": "d1", "screen_width": "1170"],
            ])
        AttributionLevel.set(.minimal)

        drain()

        let body = StubURLProtocol.requests(to: DomainConfig.logEvent).first?.body
        XCTAssertEqual(
            body?["event_name"] as? String, "purchase",
            "the enrichment filter was applied to an event and stripped it")
        XCTAssertEqual((body?["parameters"] as? [String: String])?["sku"], "A1")
        let device = body?["device"] as? [String: Any]
        XCTAssertEqual(device?["deeplinkly_device_id"] as? String, "d1")
        XCTAssertNil(device?["screen_width"])
    }

    func testErrorsAreNotRefiltered() {
        store(type: "error", payload: ["message": "boom", "stack": "trace"])

        drain()

        let body = StubURLProtocol.requests(to: DomainConfig.sdkError).first?.body
        XCTAssertEqual(body?["message"] as? String, "boom")
        XCTAssertEqual(body?["stack"] as? String, "trace")
    }

    // MARK: - The TTL

    /// "A device offline for a month would otherwise replay month-old device
    /// state as current."
    func testAnExpiredItemIsDroppedWithoutBeingSent() {
        store(type: "enrichment", payload: ["click_id": "c1"], ageInDays: 8)

        drain()

        XCTAssertTrue(RetryQueue.items().isEmpty)
        StubURLProtocol.assertNoRequest(to: DomainConfig.enrich, settle: 0)
    }

    /// The boundary the other way — and the gap that could not be closed until
    /// the send was stubbable, because an item the TTL keeps falls straight
    /// through to a real request.
    func testAnItemInsideTheWindowIsSentRatherThanSwept() {
        store(type: "enrichment", payload: ["click_id": "c1"], ageInDays: 6)

        drain()

        XCTAssertEqual(
            StubURLProtocol.requests(to: DomainConfig.enrich).count, 1,
            "an item inside the 7-day window was swept instead of sent")
    }

    /// An item written before the TTL existed carries no `queued_at`. It must
    /// not be treated as infinitely old and swept on sight.
    func testAnItemWithNoTimestampIsSentRatherThanSwept() {
        let item = "{\"type\":\"enrichment\",\"payload\":{\"click_id\":\"c1\"}}"
        UserDefaults.standard.set([item], forKey: "dl_pending_retries")

        drain()

        XCTAssertEqual(StubURLProtocol.requests(to: DomainConfig.enrich).count, 1)
    }

    // MARK: - Guards

    func testOptOutPurgesTheQueueWithoutSending() {
        store(type: "enrichment", payload: ["click_id": "c1"])
        TrackingPreferences.setTrackingDisabled(true)

        drain()

        StubURLProtocol.assertNoRequest(to: DomainConfig.enrich, settle: 0)
        XCTAssertTrue(RetryQueue.items().isEmpty, "opt-out retained a queued report")
    }

    func testAnEmptyQueueSendsNothing() {
        drain()

        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// A payload stored as a JSON *string* rather than an object is still
    /// parsed — older SDK versions wrote it that way.
    func testAStringEncodedPayloadIsStillSent() {
        let item = """
            {"type":"enrichment","payload":"{\\"click_id\\":\\"c1\\"}"}
            """
        UserDefaults.standard.set([item], forKey: "dl_pending_retries")

        drain()

        let body = StubURLProtocol.requests(to: DomainConfig.enrich).first?.body
        XCTAssertEqual(body?["click_id"] as? String, "c1")
    }
}
