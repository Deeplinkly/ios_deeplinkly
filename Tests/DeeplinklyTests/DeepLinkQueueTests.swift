import XCTest

@testable import Deeplinkly

/// The queue that makes an offline first launch survivable.
///
/// `PasteboardHandler` clears the pasteboard once it has read a link, so the
/// queue entry is the only remaining copy. Everything here is about not losing
/// it and not delivering it twice.
final class DeepLinkQueueTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    private func pending(
        clickId: String? = "click-1",
        code: String? = nil,
        uri: String = "https://example.deeplinkly.com/?click_id=click-1",
        source: String = "deep_link",
        attemptCount: Int = 0
    ) -> DeepLinkQueue.PendingResolve {
        DeepLinkQueue.PendingResolve(
            clickId: clickId, code: code, uri: uri, source: source, attemptCount: attemptCount)
    }

    // MARK: - Identity

    /// Identity is what dedupe, removal and failure accounting all key on.
    func testIdentityCombinesSourceClickIdAndCode() {
        XCTAssertEqual(
            pending(clickId: "c1", code: "abc", source: "clipboard").identity,
            "clipboard|c1|abc")
    }

    func testIdentityRepresentsMissingPartsAsEmpty() {
        XCTAssertEqual(pending(clickId: nil, code: "abc").identity, "deep_link||abc")
        XCTAssertEqual(pending(clickId: "c1", code: nil).identity, "deep_link|c1|")
    }

    /// The same link arriving through two paths is two entries, not one — the
    /// source is what the service stamps as `attribution_source`, so collapsing
    /// them would lose which mechanism recovered the install.
    func testSourceIsPartOfIdentity() {
        XCTAssertNotEqual(
            pending(source: "clipboard").identity, pending(source: "paste_control").identity)
    }

    /// Identity ignores the URI, so the same click arriving with different
    /// tracking noise on the query string is still one entry.
    func testIdentityIgnoresUri() {
        XCTAssertEqual(
            pending(uri: "https://a.example.com/x").identity,
            pending(uri: "https://b.example.com/y").identity)
    }

    // MARK: - enqueue

    func testEnqueueStoresRetrievableEntry() {
        DeepLinkQueue.enqueue(pending(clickId: "c1", code: "abc", uri: "https://x/y"))

        let all = DeepLinkQueue.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].clickId, "c1")
        XCTAssertEqual(all[0].code, "abc")
        XCTAssertEqual(all[0].uri, "https://x/y")
        XCTAssertEqual(all[0].source, "deep_link")
        XCTAssertEqual(all[0].attemptCount, 0)
    }

    /// `DeepLinkHandler` enqueues on every arrival and `PasteboardHandler`
    /// enqueues before clearing the pasteboard — the same link goes through
    /// both on a deferred launch, so enqueue has to be idempotent.
    func testEnqueueIsIdempotentOnIdentity() {
        DeepLinkQueue.enqueue(pending())
        DeepLinkQueue.enqueue(pending())
        DeepLinkQueue.enqueue(pending(uri: "https://different.example.com/"))

        XCTAssertEqual(DeepLinkQueue.all().count, 1)
    }

    /// Dedupe must not clobber progress: re-enqueueing a link that has already
    /// failed twice keeps the attempt count rather than resetting the budget.
    func testEnqueueDoesNotResetAttemptCount() {
        DeepLinkQueue.enqueue(pending())
        DeepLinkQueue.recordFailure(pending())
        DeepLinkQueue.recordFailure(pending())
        XCTAssertEqual(DeepLinkQueue.all().first?.attemptCount, 2)

        DeepLinkQueue.enqueue(pending())
        XCTAssertEqual(
            DeepLinkQueue.all().first?.attemptCount, 2,
            "re-enqueueing restarted the retry budget")
    }

    func testDistinctLinksAccumulateInOrder() {
        DeepLinkQueue.enqueue(pending(clickId: "c1"))
        DeepLinkQueue.enqueue(pending(clickId: "c2"))
        DeepLinkQueue.enqueue(pending(clickId: "c3"))

        XCTAssertEqual(DeepLinkQueue.all().map { $0.clickId }, ["c1", "c2", "c3"])
    }

    /// Bounded so a pathological app cannot grow it without limit; the oldest
    /// entries are the ones dropped.
    func testQueueIsCappedDroppingOldest() {
        for index in 0..<25 {
            DeepLinkQueue.enqueue(pending(clickId: "c\(index)"))
        }

        let all = DeepLinkQueue.all()
        XCTAssertEqual(all.count, 20)
        XCTAssertEqual(all.first?.clickId, "c5")
        XCTAssertEqual(all.last?.clickId, "c24")
    }

    // MARK: - remove

    func testRemoveDeletesByIdentityOnly() {
        DeepLinkQueue.enqueue(pending(clickId: "c1"))
        DeepLinkQueue.enqueue(pending(clickId: "c2"))

        // A different object with the same identity — which is what the
        // delivery path actually holds by the time it removes.
        DeepLinkQueue.remove(pending(clickId: "c1", uri: "https://rebuilt/"))

        XCTAssertEqual(DeepLinkQueue.all().map { $0.clickId }, ["c2"])
    }

    func testRemovingAbsentEntryIsHarmless() {
        DeepLinkQueue.enqueue(pending(clickId: "c1"))
        DeepLinkQueue.remove(pending(clickId: "nope"))
        XCTAssertEqual(DeepLinkQueue.all().count, 1)
    }

    func testClearEmptiesQueue() {
        DeepLinkQueue.enqueue(pending(clickId: "c1"))
        DeepLinkQueue.enqueue(pending(clickId: "c2"))
        DeepLinkQueue.clear()
        XCTAssertTrue(DeepLinkQueue.all().isEmpty)
    }

    // MARK: - recordFailure

    /// The return value is the decision `DeepLinkHandler` branches on: true
    /// means a later launch still owns the delivery, false means this attempt
    /// is the last word and a fallback must be delivered now.
    func testRecordFailureIncrementsAndKeepsWhileInBudget() {
        DeepLinkQueue.enqueue(pending())

        for attempt in 1..<DeepLinkQueue.maxAttempts {
            XCTAssertTrue(
                DeepLinkQueue.recordFailure(pending()), "dropped early on attempt \(attempt)")
            XCTAssertEqual(DeepLinkQueue.all().first?.attemptCount, attempt)
        }
    }

    func testRecordFailureDropsEntryOnceOutOfBudget() {
        DeepLinkQueue.enqueue(pending())

        for _ in 1..<DeepLinkQueue.maxAttempts {
            XCTAssertTrue(DeepLinkQueue.recordFailure(pending()))
        }

        XCTAssertFalse(DeepLinkQueue.recordFailure(pending()))
        XCTAssertTrue(
            DeepLinkQueue.all().isEmpty,
            "an unresolvable link stayed queued for the life of the install")
    }

    /// An entry that is not queued reports false rather than silently
    /// succeeding — the handler reads this as "no retry is coming".
    func testRecordFailureOnUnqueuedEntryReportsFalse() {
        XCTAssertFalse(DeepLinkQueue.recordFailure(pending()))
    }

    func testRecordFailureTouchesOnlyTheMatchingEntry() {
        DeepLinkQueue.enqueue(pending(clickId: "c1"))
        DeepLinkQueue.enqueue(pending(clickId: "c2"))

        DeepLinkQueue.recordFailure(pending(clickId: "c1"))

        let byClickId = Dictionary(
            uniqueKeysWithValues: DeepLinkQueue.all().map { ($0.clickId ?? "", $0.attemptCount) })
        XCTAssertEqual(byClickId["c1"], 1)
        XCTAssertEqual(byClickId["c2"], 0)
    }

    // MARK: - Persistence

    /// Entries are JSON strings in `UserDefaults`, so every field has to
    /// survive the round trip. A link the app is killed on top of is read back
    /// on the next launch by exactly this path.
    func testEntriesRoundTripThroughStorage() {
        let original = pending(
            clickId: "c1", code: "abc", uri: "https://x/y?z=1", source: "clipboard",
            attemptCount: 3)
        DeepLinkQueue.enqueue(original)

        guard let restored = DeepLinkQueue.all().first else { return XCTFail("nothing stored") }
        XCTAssertEqual(restored.clickId, original.clickId)
        XCTAssertEqual(restored.code, original.code)
        XCTAssertEqual(restored.uri, original.uri)
        XCTAssertEqual(restored.source, original.source)
        XCTAssertEqual(restored.attemptCount, original.attemptCount)
        XCTAssertEqual(restored.identity, original.identity)
    }

    func testNilClickIdAndCodeRoundTripAsAbsent() {
        DeepLinkQueue.enqueue(pending(clickId: nil, code: "abc"))
        let restored = DeepLinkQueue.all().first
        XCTAssertNil(restored?.clickId)
        XCTAssertEqual(restored?.code, "abc")
    }

    func testDictionaryInitRequiresUriAndSource() {
        XCTAssertNil(DeepLinkQueue.PendingResolve(dictionary: ["source": "deep_link"]))
        XCTAssertNil(DeepLinkQueue.PendingResolve(dictionary: ["uri": "https://x"]))
        XCTAssertNotNil(
            DeepLinkQueue.PendingResolve(dictionary: ["uri": "https://x", "source": "deep_link"]))
    }

    func testDictionaryInitDefaultsAttemptCountToZero() {
        let item = DeepLinkQueue.PendingResolve(
            dictionary: ["uri": "https://x", "source": "deep_link"])
        XCTAssertEqual(item?.attemptCount, 0)
    }

    /// Storage written by a future SDK, or corrupted on disk, must not take the
    /// queue down with it — unreadable entries are skipped and the rest survive.
    func testUnreadableStoredEntriesAreSkipped() {
        DeepLinkQueue.enqueue(pending(clickId: "c1"))
        var raw = UserDefaults.standard.array(forKey: "dl_pending_resolve") as? [String] ?? []
        raw.insert("this is not json", at: 0)
        raw.append("{\"missing\":\"required keys\"}")
        UserDefaults.standard.set(raw, forKey: "dl_pending_resolve")

        let all = DeepLinkQueue.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.clickId, "c1")
    }

    func testEmptyStorageReadsAsEmptyQueue() {
        XCTAssertTrue(DeepLinkQueue.all().isEmpty)
    }

    /// The storage key is persisted state on live installs; renaming it without
    /// a migration abandons every queued link.
    func testStorageKeyIsStable() {
        DeepLinkQueue.enqueue(pending())
        XCTAssertNotNil(
            UserDefaults.standard.array(forKey: "dl_pending_resolve"),
            "the queue is no longer stored under dl_pending_resolve")
    }

    // MARK: - Concurrency

    /// `all`, `enqueue`, `remove` and `recordFailure` are called from the
    /// resolve completion handlers, which run on URLSession's queues — the lock
    /// is what stops a read-modify-write from losing an entry.
    func testConcurrentEnqueuesAllSurvive() {
        let count = 20
        DispatchQueue.concurrentPerform(iterations: count) { index in
            DeepLinkQueue.enqueue(pending(clickId: "c\(index)"))
        }

        XCTAssertEqual(DeepLinkQueue.all().count, count)
    }

    func testConcurrentFailuresDoNotExceedTheBudget() {
        DeepLinkQueue.enqueue(pending())
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            DeepLinkQueue.recordFailure(pending())
        }
        // Whatever the interleaving, the entry is either gone or still inside
        // its budget — never left with a count past the maximum.
        if let remaining = DeepLinkQueue.all().first {
            XCTAssertLessThan(remaining.attemptCount, DeepLinkQueue.maxAttempts)
        }
    }
}
