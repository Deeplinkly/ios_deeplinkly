import XCTest

@testable import Deeplinkly

/// The rules that stop one tap becoming two `onDeepLink` calls.
///
/// Untestable until step 2 of the extraction: this logic lived as `private
/// static` state inside `DeepLinkHandler`, reachable only through a live
/// resolve. Dart does not dedupe — the method channel handler forwards
/// straight to a broadcast stream — so every rule here is the only thing
/// standing between a duplicate arrival and a duplicate delivery.
final class DeepLinkDeliveryGuardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let identity = "deep_link|c1|"

    override func setUp() {
        super.setUp()
        DeepLinkDeliveryGuard.reset()
    }

    override func tearDown() {
        DeepLinkDeliveryGuard.reset()
        super.tearDown()
    }

    // MARK: - The in-flight claim

    func testAnIdleIdentityIsClaimed() {
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle(identity, now: now))
    }

    /// Duplicate path 1: `PasteboardHandler` queues a link and resolves it
    /// immediately while `drainPendingResolves` runs the queue on the same
    /// launch. Both are in flight together.
    ///
    /// Duplicate path 2: a Universal Link reaching both the application- and
    /// scene-delegate paths, usually concurrently.
    func testASecondClaimWhileInFlightIsRefused() {
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle(identity, now: now))
        XCTAssertFalse(DeepLinkDeliveryGuard.beginIfIdle(identity, now: now))
    }

    /// The claim is released in a `defer` when the resolve completes, so a link
    /// whose resolve failed can be retried on the next launch.
    func testTheIdentityIsClaimableAgainOnceFinished() {
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle(identity, now: now))
        DeepLinkDeliveryGuard.finish(identity)
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle(identity, now: now))
    }

    /// Claims are per-identity: two different links resolving at once must not
    /// block each other.
    func testDistinctIdentitiesAreClaimedIndependently() {
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle("deep_link|c1|", now: now))
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle("deep_link|c2|", now: now))
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle("clipboard|c1|", now: now))
    }

    func testFinishingAnUnclaimedIdentityIsHarmless() {
        DeepLinkDeliveryGuard.finish("never-claimed")
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle(identity, now: now))
    }

    // MARK: - The delivered window

    /// Duplicate path 3, and the one the in-flight set cannot catch: the second
    /// arrival lands *after* the first resolve completed, so the claim is
    /// already released. Without the window `onDeepLink` fires twice.
    func testARedeliveryInsideTheWindowIsRefused() {
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle(identity, now: now))
        DeepLinkDeliveryGuard.markDelivered(identity, now: now)
        DeepLinkDeliveryGuard.finish(identity)

        XCTAssertFalse(
            DeepLinkDeliveryGuard.beginIfIdle(identity, now: now.addingTimeInterval(1)),
            "a link delivered a second ago was claimed again")
    }

    /// Short on purpose: this absorbs *mechanical* double-dispatch, which lands
    /// within milliseconds. It is not meant to decide that a user who
    /// deliberately taps the same link again later should be ignored.
    func testARedeliveryPastTheWindowIsAllowed() {
        DeepLinkDeliveryGuard.markDelivered(identity, now: now)
        XCTAssertTrue(
            DeepLinkDeliveryGuard.beginIfIdle(
                identity,
                now: now.addingTimeInterval(DeepLinkDeliveryGuard.deliveredWindow + 1)))
    }

    /// The comparison is strict, so exactly at the window the suppression has
    /// already lapsed.
    func testTheWindowBoundaryIsExclusive() {
        DeepLinkDeliveryGuard.markDelivered(identity, now: now)
        XCTAssertTrue(
            DeepLinkDeliveryGuard.beginIfIdle(
                identity, now: now.addingTimeInterval(DeepLinkDeliveryGuard.deliveredWindow)))
    }

    func testTheWindowIsTenSeconds() {
        XCTAssertEqual(DeepLinkDeliveryGuard.deliveredWindow, 10)
    }

    func testSuppressionIsPerIdentity() {
        DeepLinkDeliveryGuard.markDelivered("deep_link|c1|", now: now)
        XCTAssertFalse(DeepLinkDeliveryGuard.beginIfIdle("deep_link|c1|", now: now))
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle("deep_link|c2|", now: now))
    }

    /// The same link arriving through two different read paths is two
    /// identities — the source is what the backend stamps as
    /// `attribution_source`, so collapsing them would lose which mechanism
    /// recovered the install.
    func testTheSameLinkFromADifferentSourceIsNotSuppressed() {
        DeepLinkDeliveryGuard.markDelivered("clipboard|c1|", now: now)
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle("paste_control|c1|", now: now))
    }

    /// Suppression is recorded for a fallback as well as a resolved link: from
    /// the host app's point of view both are one `onDeepLink` for one tap, and
    /// the second arrival of a link already answered with a fallback would
    /// deliver a second one.
    func testAFallbackDeliveryAlsoSuppresses() {
        DeepLinkDeliveryGuard.markDelivered(identity, now: now)
        XCTAssertFalse(DeepLinkDeliveryGuard.beginIfIdle(identity, now: now))
    }

    /// Why the host app may keep calling `handleUniversalLink` from its own
    /// AppDelegate, which older integration guides told it to do, without
    /// seeing double deliveries.
    func testRepeatedArrivalsOfOneTapYieldOneDelivery() {
        var deliveries = 0
        for _ in 0..<5 {
            guard DeepLinkDeliveryGuard.beginIfIdle(identity, now: now) else { continue }
            DeepLinkDeliveryGuard.markDelivered(identity, now: now)
            deliveries += 1
            DeepLinkDeliveryGuard.finish(identity)
        }
        XCTAssertEqual(deliveries, 1)
    }

    // MARK: - Pruning

    /// Pruned when a link arrives rather than on a timer: the map is touched
    /// only then, so there is nothing to clean up in between. An entry past the
    /// window must not keep suppressing, and must not accumulate.
    func testExpiredEntriesStopSuppressingAfterAPrune() {
        DeepLinkDeliveryGuard.markDelivered("deep_link|old|", now: now)

        let later = now.addingTimeInterval(DeepLinkDeliveryGuard.deliveredWindow + 1)
        // Any arrival prunes; this one is for a different link.
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle("deep_link|new|", now: later))
        // The expired entry is gone, so its identity is claimable again.
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle("deep_link|old|", now: later))
    }

    /// Pruning is by age, not wholesale — a still-live suppression survives a
    /// prune triggered by another link.
    func testPruningKeepsEntriesInsideTheWindow() {
        DeepLinkDeliveryGuard.markDelivered("deep_link|recent|", now: now)

        let later = now.addingTimeInterval(1)
        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle("deep_link|other|", now: later))
        XCTAssertFalse(
            DeepLinkDeliveryGuard.beginIfIdle("deep_link|recent|", now: later),
            "a live suppression was pruned")
    }

    // MARK: - Concurrency

    /// The concurrent case is duplicate path 2 — a Universal Link on both the
    /// application and scene delegate paths. Exactly one claim may win.
    func testOnlyOneConcurrentClaimWins() {
        let won = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if DeepLinkDeliveryGuard.beginIfIdle(self.identity) {
                lock.lock()
                won.add(true)
                lock.unlock()
            }
        }
        XCTAssertEqual(won.count, 1, "\(won.count) callers claimed the same link")
    }

    func testConcurrentClaimsOnDistinctIdentitiesAllWin() {
        let won = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            if DeepLinkDeliveryGuard.beginIfIdle("deep_link|c\(index)|") {
                lock.lock()
                won.add(true)
                lock.unlock()
            }
        }
        XCTAssertEqual(won.count, 20)
    }

    func testResetClearsBothClaimsAndSuppressions() {
        _ = DeepLinkDeliveryGuard.beginIfIdle(identity, now: now)
        DeepLinkDeliveryGuard.markDelivered(identity, now: now)

        DeepLinkDeliveryGuard.reset()

        XCTAssertTrue(DeepLinkDeliveryGuard.beginIfIdle(identity, now: now))
    }
}
