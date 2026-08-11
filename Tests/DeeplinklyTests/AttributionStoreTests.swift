import XCTest

@testable import Deeplinkly

/// First-touch attribution: written once per install and never overwritten.
///
/// The listener half exists so `StartupEnrichment` can wait on attribution
/// arriving instead of polling for it once a second.
final class AttributionStoreTests: XCTestCase {

    /// Listeners live in a static dictionary that nothing else clears, so a
    /// test that registers one and does not remove it keeps firing into later
    /// tests. Every registration goes through `addListener` below so tearDown
    /// can unwind them.
    private var tokens: [UUID] = []

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        for token in tokens { AttributionStore.removeListener(token) }
        tokens = []
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    @discardableResult
    private func addListener(_ listener: @escaping ([String: Any]) -> Void) -> UUID {
        let token = AttributionStore.addListener(listener)
        tokens.append(token)
        return token
    }

    // MARK: - saveOnce

    func testSaveThenGetRoundTrips() {
        AttributionStore.saveOnce(map: ["click_id": "c1", "utm_source": "news"])

        let stored = AttributionStore.get()
        XCTAssertEqual(stored["click_id"] as? String, "c1")
        XCTAssertEqual(stored["utm_source"] as? String, "news")
    }

    /// First touch means first: a second link arriving later must not rewrite
    /// what the install is attributed to.
    func testSecondSaveIsIgnored() {
        AttributionStore.saveOnce(map: ["click_id": "first"])
        AttributionStore.saveOnce(map: ["click_id": "second", "utm_source": "news"])

        let stored = AttributionStore.get()
        XCTAssertEqual(stored["click_id"] as? String, "first")
        XCTAssertNil(stored["utm_source"], "a later save merged into first-touch attribution")
    }

    /// Nil values are compacted away rather than stored as nulls — the map
    /// arrives from `attributionSnapshot`, which carries nil for every key the
    /// link did not have.
    func testNilValuesAreDropped() {
        AttributionStore.saveOnce(map: ["click_id": "c1", "utm_source": nil])

        let stored = AttributionStore.get()
        XCTAssertEqual(Set(stored.keys), ["click_id"])
    }

    /// An all-nil map still latches — it compacts to `{}`, which is stored and
    /// counts as the first touch. Pinned because it means a fallback delivery
    /// with no attribution on it closes the window for a later real one.
    func testAnEmptyMapStillLatches() {
        AttributionStore.saveOnce(map: ["click_id": nil])
        XCTAssertTrue(AttributionStore.get().isEmpty)

        AttributionStore.saveOnce(map: ["click_id": "c1"])
        XCTAssertTrue(
            AttributionStore.get().isEmpty,
            "an empty first touch did not latch, or a later save overwrote it")
    }

    func testGetOnEmptyStoreIsEmpty() {
        XCTAssertTrue(AttributionStore.get().isEmpty)
    }

    /// Corrupt storage reads as empty rather than crashing, and — because the
    /// key is still occupied — is not overwritten by a later save.
    func testUnreadableStorageReadsAsEmpty() {
        UserDefaults.standard.set("{ not json", forKey: "initial_attribution")
        XCTAssertTrue(AttributionStore.get().isEmpty)
    }

    /// Persisted state on live installs; the key is frozen.
    func testStorageKeyIsStable() {
        AttributionStore.saveOnce(map: ["click_id": "c1"])
        XCTAssertNotNil(UserDefaults.standard.string(forKey: "initial_attribution"))
    }

    // MARK: - Listeners

    func testListenerIsNotifiedOnFirstSave() {
        var received: [String: Any]?
        addListener { received = $0 }

        AttributionStore.saveOnce(map: ["click_id": "c1"])

        XCTAssertEqual(received?["click_id"] as? String, "c1")
    }

    /// The notification carries the compacted map, matching what was stored.
    func testListenerReceivesTheCompactedMap() {
        var received: [String: Any]?
        addListener { received = $0 }

        AttributionStore.saveOnce(map: ["click_id": "c1", "gclid": nil])

        XCTAssertEqual(Set((received ?? [:]).keys), ["click_id"])
    }

    /// A save that is ignored notifies nobody — otherwise `StartupEnrichment`
    /// would wake on a write that changed nothing.
    func testIgnoredSaveDoesNotNotify() {
        AttributionStore.saveOnce(map: ["click_id": "first"])

        var notified = false
        addListener { _ in notified = true }
        AttributionStore.saveOnce(map: ["click_id": "second"])

        XCTAssertFalse(notified)
    }

    func testEveryListenerIsNotified() {
        var count = 0
        addListener { _ in count += 1 }
        addListener { _ in count += 1 }
        addListener { _ in count += 1 }

        AttributionStore.saveOnce(map: ["click_id": "c1"])

        XCTAssertEqual(count, 3)
    }

    /// Removal has to work, or `StartupEnrichment`'s `defer` leaks a closure
    /// capturing a semaphore on every launch.
    func testRemovedListenerIsNotNotified() {
        var notified = false
        let token = addListener { _ in notified = true }
        AttributionStore.removeListener(token)

        AttributionStore.saveOnce(map: ["click_id": "c1"])

        XCTAssertFalse(notified)
    }

    func testRemovingOneListenerLeavesTheOthers() {
        var kept = false
        let removed = addListener { _ in XCTFail("removed listener fired") }
        addListener { _ in kept = true }
        AttributionStore.removeListener(removed)

        AttributionStore.saveOnce(map: ["click_id": "c1"])

        XCTAssertTrue(kept)
    }

    func testAddListenerReturnsDistinctTokens() {
        let first = addListener { _ in }
        let second = addListener { _ in }
        XCTAssertNotEqual(first, second)
        AttributionStore.removeListener(first)
        AttributionStore.removeListener(second)
    }

    func testRemovingAnUnknownTokenIsHarmless() {
        AttributionStore.removeListener(UUID())
    }

    /// Listeners are notified outside the lock, so one that re-enters the store
    /// — reading it, or registering another listener — must not deadlock. The
    /// notification is sent after the write, so the value is already readable.
    func testListenerMayTouchTheStoreWhileBeingNotified() {
        var readBack: String?
        addListener { _ in
            readBack = AttributionStore.get()["click_id"] as? String
            self.addListener { _ in }
        }

        AttributionStore.saveOnce(map: ["click_id": "c1"])

        XCTAssertEqual(readBack, "c1", "a listener could not read the store it was notified about")
    }
}
