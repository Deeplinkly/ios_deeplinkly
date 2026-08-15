import XCTest

@testable import Deeplinkly

/// The single delivery funnel, and the readiness gate in front of it.
///
/// The reason the gate exists: `invokeMethod` to a channel Dart has not
/// registered a handler for *succeeds silently*, so delivering before
/// `FlutterDeeplinkly.init()` has attached its `onDeepLink` handler drops the
/// payload with no error anywhere. Every deferred deep link was lost this way
/// before the buffer.
///
/// These tests run on the main thread, where `deliver` calls the listener
/// synchronously — so ordering assertions are deterministic rather than
/// timing-dependent. The off-main-thread hop has its own test.
final class SdkRuntimeTests: XCTestCase {

    private var listener: RecordingDeepLinkListener!

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        listener = RecordingDeepLinkListener()
        drainBuffer()
    }

    override func tearDown() {
        drainBuffer()
        super.tearDown()
    }

    /// `clearListener` deliberately keeps the buffer, so a test cannot start
    /// from a clean slate without flushing what an earlier one left behind.
    private func drainBuffer() {
        SdkRuntime.setListener(RecordingDeepLinkListener())
        SdkRuntime.clearListener()
    }

    // MARK: - Readiness

    func testNotReadyUntilAListenerAttaches() {
        XCTAssertFalse(SdkRuntime.isReady())
    }

    func testReadyOnceAListenerAttaches() {
        SdkRuntime.setListener(listener)
        XCTAssertTrue(SdkRuntime.isReady())
    }

    func testNotReadyAgainAfterDetach() {
        SdkRuntime.setListener(listener)
        SdkRuntime.clearListener()
        XCTAssertFalse(SdkRuntime.isReady())
    }

    // MARK: - Delivery when ready

    func testDeliversImmediatelyWhenReady() {
        SdkRuntime.setListener(listener)
        SdkRuntime.deliverDeepLink(["click_id": "c1"])

        XCTAssertEqual(listener.count, 1)
        XCTAssertEqual(listener.clickIds, ["c1"])
    }

    /// `onDelivered` is what lets a caller hold durable state until delivery is
    /// real: `DeepLinkHandler` only drops the queue entry inside it.
    func testOnDeliveredRunsAfterTheListenerHasSeenIt() {
        SdkRuntime.setListener(listener)

        var countWhenDelivered: Int?
        SdkRuntime.deliverDeepLink([:]) { countWhenDelivered = self.listener.count }

        XCTAssertEqual(
            countWhenDelivered, 1, "onDelivered ran before the listener was called")
    }

    /// The payload is forwarded unchanged — the typed accessors read from it,
    /// and parsing and re-serialising would put a lossy round trip in the one
    /// path that has to be exact.
    func testPayloadIsForwardedIntact() {
        SdkRuntime.setListener(listener)
        SdkRuntime.deliverDeepLink([
            "click_id": "c1",
            "params": ["utm_source": "news", "count": 3],
        ])

        let payload = listener.received.first
        XCTAssertEqual(payload?["click_id"] as? String, "c1")
        let params = payload?["params"] as? [String: Any]
        XCTAssertEqual(params?["utm_source"] as? String, "news")
        XCTAssertEqual(params?["count"] as? Int, 3)
    }

    // MARK: - Buffering when nothing is listening

    func testBuffersInsteadOfDroppingWhenNothingIsListening() {
        SdkRuntime.deliverDeepLink(["click_id": "c1"])
        XCTAssertEqual(listener.count, 0)

        SdkRuntime.setListener(listener)
        XCTAssertEqual(listener.clickIds, ["c1"])
    }

    func testFlushPreservesOrder() {
        SdkRuntime.deliverDeepLink(["click_id": "first"])
        SdkRuntime.deliverDeepLink(["click_id": "second"])
        SdkRuntime.deliverDeepLink(["click_id": "third"])

        SdkRuntime.setListener(listener)
        XCTAssertEqual(listener.clickIds, ["first", "second", "third"])
    }

    /// A buffered link's `onDelivered` must not run at buffer time — that would
    /// drop the queue entry for a link that has not arrived, and being killed
    /// before the flush would lose it with the pasteboard copy long gone.
    func testOnDeliveredIsWithheldUntilFlush() {
        var delivered = false
        SdkRuntime.deliverDeepLink([:]) { delivered = true }
        XCTAssertFalse(delivered, "onDelivered ran while the link was still buffered")

        SdkRuntime.setListener(listener)
        XCTAssertTrue(delivered, "onDelivered never ran after the flush")
    }

    func testFlushRunsEveryCallbackOnce() {
        var calls: [String] = []
        SdkRuntime.deliverDeepLink(["click_id": "a"]) { calls.append("a") }
        SdkRuntime.deliverDeepLink(["click_id": "b"]) { calls.append("b") }

        SdkRuntime.setListener(listener)
        XCTAssertEqual(calls, ["a", "b"])
    }

    /// The buffer is drained by the flush, not merely replayed from — a second
    /// attach must not deliver the same link again.
    func testBufferIsEmptiedByTheFlush() {
        SdkRuntime.deliverDeepLink(["click_id": "c1"])
        SdkRuntime.setListener(listener)
        XCTAssertEqual(listener.count, 1)

        listener.reset()
        SdkRuntime.clearListener()
        SdkRuntime.setListener(listener)
        XCTAssertEqual(listener.count, 0, "the buffer replayed on a second attach")
    }

    /// Bounded so a host app that never attaches a listener cannot grow it
    /// without limit. Oldest goes first — the newest link is the one the user
    /// just tapped.
    func testBufferIsCappedDroppingOldest() {
        for index in 0..<25 {
            SdkRuntime.deliverDeepLink(["click_id": "c\(index)"])
        }
        SdkRuntime.setListener(listener)

        XCTAssertEqual(listener.count, 20)
        XCTAssertEqual(listener.clickIds.first, "c5")
        XCTAssertEqual(listener.clickIds.last, "c24")
    }

    // MARK: - Listener identity

    /// Attaching again replaces the listener rather than adding one, so a
    /// re-attach after an engine detach does not fan a link out to a stale
    /// receiver.
    func testAttachingAgainReplacesTheListener() {
        let stale = RecordingDeepLinkListener()
        SdkRuntime.setListener(stale)
        SdkRuntime.setListener(listener)

        SdkRuntime.deliverDeepLink(["click_id": "c1"])

        XCTAssertEqual(listener.count, 1)
        XCTAssertEqual(stale.count, 0, "a replaced listener still received a link")
    }

    func testFlushGoesToTheListenerThatAttached() {
        let stale = RecordingDeepLinkListener()
        SdkRuntime.deliverDeepLink(["click_id": "c1"])

        SdkRuntime.setListener(listener)

        XCTAssertEqual(listener.count, 1)
        XCTAssertEqual(stale.count, 0)
    }

    // MARK: - Lifecycle

    /// An engine detach followed by a re-attach — a Flutter app backgrounded
    /// and restored, or a second engine — buffers rather than drops in between.
    func testLinksArrivingWhileDetachedAreBufferedForTheNextAttach() {
        SdkRuntime.setListener(listener)
        SdkRuntime.clearListener()

        SdkRuntime.deliverDeepLink(["click_id": "c1"])
        XCTAssertEqual(listener.count, 0)

        SdkRuntime.setListener(listener)
        XCTAssertEqual(listener.clickIds, ["c1"])
    }

    func testFlushWithAnEmptyBufferDeliversNothing() {
        SdkRuntime.setListener(listener)
        XCTAssertEqual(listener.count, 0)
    }

    // MARK: - Threading

    /// Listeners touch the Flutter channel and, for a native integrator, UIKit
    /// — both main-thread only. Resolves complete on a URLSession queue, so
    /// this hop is on every real delivery.
    func testDeliveryFromABackgroundQueueLandsOnTheMainThread() {
        SdkRuntime.setListener(listener)

        let delivered = expectation(description: "delivered")
        DispatchQueue.global(qos: .utility).async {
            SdkRuntime.deliverDeepLink(["click_id": "c1"]) { delivered.fulfill() }
        }
        wait(for: [delivered], timeout: 5)

        XCTAssertEqual(listener.receivedOnMainThread, [true])
    }

    /// The ordering bug this funnel fixed: `onDelivered` used to run
    /// synchronously while the delivery itself was dispatched async, so a link
    /// resolved off the main thread had its durable queue entry dropped before
    /// it had been handed to anyone.
    func testOnDeliveredStillRunsAfterTheListenerWhenHoppingThreads() {
        SdkRuntime.setListener(listener)

        var order: [String] = []
        listener.onReceive = { order.append("listener") }

        let delivered = expectation(description: "delivered")
        DispatchQueue.global(qos: .utility).async {
            SdkRuntime.deliverDeepLink(["click_id": "c1"]) {
                order.append("onDelivered")
                delivered.fulfill()
            }
        }
        wait(for: [delivered], timeout: 5)

        XCTAssertEqual(order, ["listener", "onDelivered"])
    }

    /// Deliveries arrive from URLSession completion handlers, so the buffer is
    /// written from arbitrary queues. Nothing may be lost or doubled.
    func testConcurrentDeliveriesAreAllBufferedAndFlushedOnce() {
        let count = 15
        DispatchQueue.concurrentPerform(iterations: count) { index in
            SdkRuntime.deliverDeepLink(["click_id": "c\(index)"])
        }

        SdkRuntime.setListener(listener)
        XCTAssertEqual(listener.count, count)
        XCTAssertEqual(Set(listener.clickIds.compactMap { $0 }).count, count, "a link was doubled")
    }
}

