import XCTest

@testable import Deeplinkly

/// Durable storage for payloads that failed to send.
///
/// iOS used to store this under `sdk_retry_queue`. It now shares Android's
/// `dl_pending_retries` key and migrates the legacy value on first access.
final class RetryQueueTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    private func decoded(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    // MARK: - enqueue

    func testEnqueueStoresTypeAndPayload() {
        RetryQueue.enqueue(type: "enrichment", payload: ["click_id": "c1"])

        let items = RetryQueue.items()
        XCTAssertEqual(items.count, 1)
        let item = decoded(items[0])
        XCTAssertEqual(item["type"] as? String, "enrichment")
        XCTAssertEqual((item["payload"] as? [String: Any])?["click_id"] as? String, "c1")
    }

    /// The timestamp is what the TTL is measured against. Without it a device
    /// offline for a month replays month-old device state as current.
    func testEnqueueStampsQueuedAt() {
        let before = Date().timeIntervalSince1970
        RetryQueue.enqueue(type: "event", payload: [:])
        let after = Date().timeIntervalSince1970

        let queuedAt = decoded(RetryQueue.items()[0])["queued_at"] as? TimeInterval
        XCTAssertNotNil(queuedAt)
        XCTAssertGreaterThanOrEqual(queuedAt ?? 0, before)
        XCTAssertLessThanOrEqual(queuedAt ?? 0, after)
    }

    /// Unlike `DeepLinkQueue`, this queue does not dedupe — two failed sends of
    /// the same payload are two things to retry.
    func testEnqueueDoesNotDedupe() {
        RetryQueue.enqueue(type: "event", payload: ["name": "purchase"])
        RetryQueue.enqueue(type: "event", payload: ["name": "purchase"])
        XCTAssertEqual(RetryQueue.items().count, 2)
    }

    func testQueueIsCappedDroppingOldest() {
        for index in 0..<55 {
            RetryQueue.enqueue(type: "event", payload: ["index": index])
        }

        let items = RetryQueue.items()
        XCTAssertEqual(items.count, 50)
        XCTAssertEqual((decoded(items[0])["payload"] as? [String: Any])?["index"] as? Int, 5)
        XCTAssertEqual((decoded(items[49])["payload"] as? [String: Any])?["index"] as? Int, 54)
    }

    func testNestedPayloadsRoundTrip() {
        RetryQueue.enqueue(
            type: "event",
            payload: ["event_name": "purchase", "device": ["platform": "ios"], "count": 3])

        let payload = decoded(RetryQueue.items()[0])["payload"] as? [String: Any]
        XCTAssertEqual(payload?["event_name"] as? String, "purchase")
        XCTAssertEqual((payload?["device"] as? [String: Any])?["platform"] as? String, "ios")
        XCTAssertEqual(payload?["count"] as? Int, 3)
    }

    func testEnqueueIsSuppressedWhileTrackingIsDisabled() {
        TrackingPreferences.setTrackingDisabled(true)

        RetryQueue.enqueue(type: "event", payload: ["name": "purchase"])

        XCTAssertTrue(RetryQueue.items().isEmpty)
    }

    // MARK: - remove

    func testRemoveDeletesTheMatchingItem() {
        RetryQueue.enqueue(type: "event", payload: ["index": 1])
        RetryQueue.enqueue(type: "event", payload: ["index": 2])

        let first = RetryQueue.items()[0]
        RetryQueue.remove(first)

        XCTAssertEqual(RetryQueue.items().count, 1)
        XCTAssertFalse(RetryQueue.items().contains(first))
    }

    func testRemovingAnAbsentItemIsHarmless() {
        RetryQueue.enqueue(type: "event", payload: [:])
        RetryQueue.remove("not in the queue")
        XCTAssertEqual(RetryQueue.items().count, 1)
    }

    /// Removal is by exact string and deletes one occurrence, so two identical
    /// payloads do not collapse when one of them drains.
    func testRemoveDeletesOnlyOneOfTwoIdenticalItems() {
        RetryQueue.enqueue(type: "event", payload: ["name": "purchase"])
        let items = RetryQueue.items()
        // Two enqueues a moment apart differ only in queued_at; force the
        // genuinely-identical case the dedupe-free queue can produce.
        seedQueue([items[0], items[0]])

        RetryQueue.remove(items[0])
        XCTAssertEqual(RetryQueue.items().count, 1)
    }

    func testItemsOnEmptyStorageIsEmpty() {
        XCTAssertTrue(RetryQueue.items().isEmpty)
    }

    // MARK: - refilter

    /// Retry items are stored fully assembled and already filtered, so without
    /// this a level downgrade between queueing and sending is never honoured
    /// for anything already in the queue.
    func testRefilterAppliesTheLevelInForceNow() {
        let payload: [String: Any] = [
            "click_id": "c1", "utm_source": "news", "screen_width": "1170",
        ]

        AttributionLevel.set(.full)
        XCTAssertEqual(RetryQueue.refilter(payload).count, 3)

        AttributionLevel.set(.reduced)
        XCTAssertEqual(Set(RetryQueue.refilter(payload).keys), ["click_id", "utm_source"])

        AttributionLevel.set(.minimal)
        XCTAssertEqual(Set(RetryQueue.refilter(payload).keys), ["click_id"])

        AttributionLevel.set(.none)
        XCTAssertTrue(RetryQueue.refilter(payload).isEmpty)
    }

    func testRefilterHonoursTrackingDisabled() {
        AttributionLevel.set(.full)
        TrackingPreferences.setTrackingDisabled(true)
        XCTAssertTrue(RetryQueue.refilter(["click_id": "c1"]).isEmpty)
    }

    /// Fail-closed reaches the retry path too: an item stored by an older SDK
    /// carrying a key this build does not catalogue is stripped rather than
    /// replayed.
    func testRefilterDropsUncataloguedKeys() {
        AttributionLevel.set(.full)
        let out = RetryQueue.refilter(["click_id": "c1", "retired_signal": "x"])
        XCTAssertEqual(Set(out.keys), ["click_id"])
    }

    func testQueuedEventDeviceBlockIsRefilteredWithoutChangingEventData() {
        let event: [String: Any] = [
            "event_name": "purchase",
            "parameters": ["sku": "A1"],
            "device": [
                "deeplinkly_device_id": "device-1",
                "click_id": "click-1",
                "locale": "en-GB",
                "screen_width": "1170",
            ],
        ]
        AttributionLevel.set(.minimal)

        let out = RetryQueue.refilterEvent(event)

        XCTAssertEqual(out["event_name"] as? String, "purchase")
        XCTAssertEqual((out["parameters"] as? [String: String])?["sku"], "A1")
        XCTAssertEqual(
            Set((out["device"] as? [String: Any])?.keys.map { $0 } ?? []),
            ["deeplinkly_device_id", "click_id"])
    }

    func testQueuedEventLosesItsDeviceBlockAtNone() {
        let event: [String: Any] = [
            "event_name": "purchase",
            "device": ["deeplinkly_device_id": "device-1"],
        ]
        AttributionLevel.set(.none)

        let out = RetryQueue.refilterEvent(event)

        XCTAssertEqual(out["event_name"] as? String, "purchase")
        XCTAssertNil(out["device"])
    }

    // MARK: - retryAll

    /// Opt-out deletes reports queued under an earlier consent state rather
    /// than retaining them for a surprise replay after opt-in.
    func testDisablingTrackingPurgesTheRetryQueue() {
        RetryQueue.enqueue(type: "enrichment", payload: ["click_id": "c1"])
        XCTAssertEqual(RetryQueue.items().count, 1)

        TrackingPreferences.setTrackingDisabled(true)

        XCTAssertTrue(RetryQueue.items().isEmpty, "opt-out retained a queued report")
    }

    func testRetryAllPurgesALegacyQueueWhileTrackingIsDisabled() {
        TrackingPreferences.setTrackingDisabled(true)
        UserDefaults.standard.set(["legacy"], forKey: "sdk_retry_queue")

        RetryQueue.retryAll(apiKey: "test-key")

        XCTAssertNil(UserDefaults.standard.object(forKey: "sdk_retry_queue"))
        XCTAssertTrue(RetryQueue.items().isEmpty)
    }

    /// Every `retryAll` case exercised below is one that provably issues no
    /// request. The send-dispatch paths are deliberately not covered: they call
    /// `sendNow`, which blocks on a semaphore around a live request to
    /// `DomainConfig`'s production host, and the service is production. Making
    /// them testable needs an injectable base URL or `URLSession` — see
    /// `SEAM_TESTS.md`.
    ///
    /// An entry that is not JSON, or that carries no `type`, is skipped and
    /// left in place for a later launch to reconsider.
    func testMalformedItemsAreSkippedAndKept() {
        UserDefaults.standard.set(
            ["not json at all", "{\"payload\":{}}"], forKey: "dl_pending_retries")

        RetryQueue.retryAll(apiKey: "test-key")

        XCTAssertEqual(RetryQueue.items().count, 2)
    }

    /// An entry naming a type this build does not know is dropped rather than
    /// reconsidered forever — the switch's default falls through to the same
    /// `remove` a successful send uses.
    func testUnknownTypeIsDroppedRatherThanRetriedForever() {
        UserDefaults.standard.set(
            ["{\"type\":\"mystery\",\"payload\":{}}"], forKey: "dl_pending_retries")

        RetryQueue.retryAll(apiKey: "test-key")

        XCTAssertTrue(RetryQueue.items().isEmpty)
    }

    /// Items past the 7-day TTL are dropped before the switch, so an expired
    /// payload is never sent whatever the network would have said. Without
    /// this, a device offline for a month reports month-old device state as
    /// current when it reconnects.
    func testItemsPastTheTtlAreDroppedWithoutSending() {
        storeItem(type: "enrichment", ageInDays: 8)

        RetryQueue.retryAll(apiKey: "test-key")

        XCTAssertTrue(RetryQueue.items().isEmpty, "an expired item survived the TTL sweep")
    }

    /// The boundary the other way — an item inside the window surviving the
    /// sweep — is **not** covered, and cannot be without injection: an item the
    /// TTL keeps falls straight through to a real send, and one given an
    /// unknown type to avoid that is removed by the default branch instead. The
    /// queue cannot distinguish the two removals. `SEAM_TESTS.md` records this.
    private func storeItem(type: String, ageInDays: Double) {
        let item: [String: Any] = [
            "type": type,
            "payload": ["click_id": "c1"],
            "queued_at": Date().timeIntervalSince1970 - (ageInDays * 24 * 60 * 60),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: item),
            let encoded = String(data: data, encoding: .utf8)
        else { return XCTFail("could not encode fixture") }
        seedQueue([encoded])
    }

    /// Writes the queue where the queue actually lives.
    ///
    /// Going through `UserDefaults` would work — `items()` would migrate it —
    /// but then every drain test would depend on the migration path, and a bug
    /// there would surface as unrelated failures somewhere else.
    private func seedQueue(_ items: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: items),
            let json = String(data: data, encoding: .utf8)
        else { return XCTFail("could not encode queue") }
        Keychain.set(json, for: "dl_pending_retries", accessibility: Keychain.thisDeviceOnly)
    }

    /// The queue as the Keychain holds it, or nil when nothing is stored.
    private func storedQueue() -> [String]? {
        guard let raw = Keychain.get("dl_pending_retries"),
            let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String]
    }

    // MARK: - Storage contract

    /// New writes use the cross-platform key, in the Keychain, and never
    /// recreate either plist entry.
    func testStorageKeyIsStable() {
        RetryQueue.enqueue(type: "event", payload: [:])
        XCTAssertNotNil(
            storedQueue(),
            "the retry queue is no longer stored under dl_pending_retries")
        XCTAssertNil(UserDefaults.standard.object(forKey: "sdk_retry_queue"))
    }

    /// The reason this store moved: a queued enrichment carries whatever
    /// `setUserData` was given, and `UserDefaults` is a plist that rides into
    /// device backups and restores onto other hardware. `UserDataStore` moved
    /// to the Keychain for exactly that reason and the queue was putting the
    /// same values straight back.
    ///
    /// What this can and cannot see: which store was written is observable, and
    /// is asserted below. The protection class is not — package tests run
    /// against `Keychain`'s in-memory store, which ignores it — and neither is
    /// the backup behaviour that is the actual point. Same seam
    /// `UserDataStoreTests.testIsStoredInTheKeychainAndNotInUserDefaults`
    /// documents.
    func testAQueuedPayloadNeverTouchesUserDefaults() {
        RetryQueue.enqueue(
            type: "enrichment",
            payload: ["user_email": "ada@example.com", "user_phone": "+15555550123"])

        XCTAssertNil(UserDefaults.standard.object(forKey: "dl_pending_retries"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "sdk_retry_queue"))

        // Belt and braces: no plist entry anywhere holds the address, whatever
        // it is keyed under.
        let plist = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in plist {
            XCTAssertFalse(
                String(describing: value).contains("ada@example.com"),
                "personal data reached UserDefaults under \(key)")
        }

        // And it is genuinely still queued — the point is to move it, not to
        // drop it.
        XCTAssertEqual(RetryQueue.items().count, 1)
        XCTAssertTrue(RetryQueue.items()[0].contains("ada@example.com"))
    }

    /// A privacy reset has to reach the Keychain copy; the UserDefaults sweep
    /// in `PrivacyData` cannot.
    func testClearRemovesTheKeychainCopy() {
        RetryQueue.enqueue(type: "event", payload: [:])
        XCTAssertNotNil(storedQueue())

        RetryQueue.clear()

        XCTAssertNil(storedQueue())
        XCTAssertTrue(RetryQueue.items().isEmpty)
    }

    /// Draining the last item leaves no empty husk behind in the Keychain.
    func testEmptyingTheQueueDeletesTheItem() {
        RetryQueue.enqueue(type: "event", payload: [:])
        RetryQueue.remove(RetryQueue.items()[0])

        XCTAssertNil(storedQueue())
    }

    /// Payloads queued by an older iOS SDK survive the key rename *and* the
    /// move to the Keychain. These are undelivered payloads; an SDK upgrade is
    /// no reason to lose them.
    func testLegacyStorageIsMovedAndDeletedOnFirstAccess() {
        let legacyItems = ["legacy item"]
        UserDefaults.standard.set(legacyItems, forKey: "sdk_retry_queue")

        XCTAssertEqual(RetryQueue.items(), legacyItems)
        XCTAssertEqual(storedQueue(), legacyItems)
        XCTAssertNil(UserDefaults.standard.object(forKey: "sdk_retry_queue"))
    }

    /// A queue written to the plist by the build immediately before this one
    /// is carried into the Keychain, and the plist copy does not survive it.
    /// That copy is the exposure the move exists to end, so leaving it would
    /// defeat the change for every device that upgrades with a backlog.
    func testAPlistQueueIsMovedIntoTheKeychainAndErased() {
        UserDefaults.standard.set(["pending item"], forKey: "dl_pending_retries")

        XCTAssertEqual(RetryQueue.items(), ["pending item"])
        XCTAssertEqual(storedQueue(), ["pending item"])
        XCTAssertNil(UserDefaults.standard.object(forKey: "dl_pending_retries"))
    }

    /// The Keychain wins over a stale plist copy: that state means the
    /// migration already ran and these are its leftovers, not newer data.
    func testTheKeychainWinsOverALeftoverPlistQueue() {
        seedQueue(["keychain item"])
        UserDefaults.standard.set(["stale plist item"], forKey: "dl_pending_retries")

        XCTAssertEqual(RetryQueue.items(), ["keychain item"])
        XCTAssertNil(UserDefaults.standard.object(forKey: "dl_pending_retries"))
    }

    /// If cleanup was interrupted after the canonical write, retrying the
    /// migration must not duplicate or replace the canonical queue.
    func testInterruptedMigrationKeepsCanonicalStorage() {
        UserDefaults.standard.set(["legacy item"], forKey: "sdk_retry_queue")
        UserDefaults.standard.set(["canonical item"], forKey: "dl_pending_retries")

        XCTAssertEqual(RetryQueue.items(), ["canonical item"])
        XCTAssertNil(UserDefaults.standard.object(forKey: "sdk_retry_queue"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "dl_pending_retries"))
    }

    /// The three types `retryAll` dispatches on. A payload stored under a type
    /// the switch does not know is silently never sent.
    func testEveryEnqueuedTypeIsOneRetryAllHandles() {
        for type in ["enrichment", "error", "event"] {
            RetryQueue.enqueue(type: type, payload: [:])
        }
        let types = RetryQueue.items().compactMap { decoded($0)["type"] as? String }
        XCTAssertEqual(Set(types), ["enrichment", "error", "event"])
    }
}
