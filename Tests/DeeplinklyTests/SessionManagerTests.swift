import XCTest

@testable import Deeplinkly

/// A session is a 30-minute inactivity window. It is what makes an event
/// joinable to the device sample taken alongside it — without it a sample and
/// an event from the same visit have nothing but a timestamp in common.
///
/// `currentSessionId(now:)` takes an injectable clock, so all of this is
/// deterministic rather than sleep-based.
final class SessionManagerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    func testFirstCallStartsASession() {
        let id = SessionManager.currentSessionId(now: start)
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotNil(UUID(uuidString: id), "session id is not a UUID: \(id)")
    }

    func testSameSessionInsideTheWindow() {
        let first = SessionManager.currentSessionId(now: start)
        let second = SessionManager.currentSessionId(now: start.addingTimeInterval(29 * 60))
        XCTAssertEqual(first, second)
    }

    func testNewSessionOnceTheWindowLapses() {
        let first = SessionManager.currentSessionId(now: start)
        let second = SessionManager.currentSessionId(
            now: start.addingTimeInterval(SessionManager.sessionWindow + 1))
        XCTAssertNotEqual(first, second)
    }

    /// Exactly at the boundary the session is still live — the window is
    /// inclusive (`<=`), and an off-by-one here splits a visit in two.
    func testTheWindowBoundaryIsInclusive() {
        let first = SessionManager.currentSessionId(now: start)
        let second = SessionManager.currentSessionId(
            now: start.addingTimeInterval(SessionManager.sessionWindow))
        XCTAssertEqual(first, second)
    }

    /// "Any open or event inside the window extends it" — so simply asking
    /// touches the activity timestamp. Three reads 20 minutes apart span an
    /// hour and are still one session.
    func testActivityExtendsTheSession() {
        let first = SessionManager.currentSessionId(now: start)
        _ = SessionManager.currentSessionId(now: start.addingTimeInterval(20 * 60))
        let last = SessionManager.currentSessionId(now: start.addingTimeInterval(40 * 60))
        XCTAssertEqual(first, last)
    }

    /// The counterpart: without a touch in between, the same 40-minute gap
    /// starts a new session.
    func testAnUntouchedGapStartsANewSession() {
        let first = SessionManager.currentSessionId(now: start)
        let last = SessionManager.currentSessionId(now: start.addingTimeInterval(40 * 60))
        XCTAssertNotEqual(first, last)
    }

    /// Persisted rather than held in memory, so a session survives the process
    /// being killed and relaunched inside the window.
    func testSessionIsPersisted() {
        let id = SessionManager.currentSessionId(now: start)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "dl_session_id"), id)
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: "dl_session_last_at"),
            start.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A stored id with no timestamp — or a timestamp far in the past — must
    /// start a fresh session rather than resurrect an ancient one.
    func testAStoredIdWithNoTimestampStartsAfresh() {
        UserDefaults.standard.set("stale-session", forKey: "dl_session_id")
        XCTAssertNotEqual(SessionManager.currentSessionId(now: start), "stale-session")
    }

    func testSessionsAreDistinctAcrossWindows() {
        var ids: Set<String> = []
        for index in 0..<5 {
            let now = start.addingTimeInterval(Double(index) * (SessionManager.sessionWindow + 60))
            ids.insert(SessionManager.currentSessionId(now: now))
        }
        XCTAssertEqual(ids.count, 5)
    }

    func testWindowIsThirtyMinutes() {
        XCTAssertEqual(SessionManager.sessionWindow, 30 * 60)
    }

    /// Called from event logging and from the dynamic collector, potentially
    /// concurrently — one visit must not fragment into several sessions.
    func testConcurrentReadsAgreeOnOneSession() {
        let ids = NSMutableSet()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            let id = SessionManager.currentSessionId()
            lock.lock()
            ids.add(id)
            lock.unlock()
        }
        XCTAssertEqual(ids.count, 1, "concurrent reads minted \(ids.count) sessions")
    }
}
