import XCTest

@testable import Deeplinkly

/// The request-issuing half of `NetworkUtils` — everything that was untestable
/// until `session` became injectable.
final class NetworkRequestTests: XCTestCase {

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

    // MARK: - Headers

    /// Every call carries the key as a bearer token and both identity headers —
    /// they are read off the request headers.
    func testEveryRequestCarriesAuthAndIdentityHeaders() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok(["click_id": "c1"]))
        Prefs.setCustomUserId("user-1")

        resolve(clickId: "c1")

        let request = StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick).first
        XCTAssertEqual(request?.headers["Authorization"], "Bearer test-key")
        XCTAssertEqual(request?.headers["Accept"], "application/json")
        XCTAssertEqual(request?.headers["X-Deeplinkly-Custom-User-Id"], "user-1")
        XCTAssertEqual(
            request?.headers["X-Deeplinkly-User-Id"], DeviceIdManager.getOrCreate())
    }

    /// The custom id header is omitted rather than sent empty when no user has
    /// been identified.
    func testCustomUserIdHeaderIsAbsentUntilAUserIsIdentified() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok())

        resolve(clickId: "c1")

        let request = StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick).first
        XCTAssertNil(request?.headers["X-Deeplinkly-Custom-User-Id"])
    }

    func testFunctionalRequestOmitsIdentityHeadersWhileTrackingIsDisabled() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok())
        Prefs.setCustomUserId("user-1")
        _ = DeviceIdManager.getOrCreate()
        TrackingPreferences.setTrackingDisabled(true)

        resolve(clickId: "c1")

        let request = StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick).first
        XCTAssertEqual(request?.headers["Authorization"], "Bearer test-key")
        XCTAssertNil(request?.headers["X-Deeplinkly-Custom-User-Id"])
        XCTAssertNil(request?.headers["X-Deeplinkly-User-Id"])
    }

    func testPostsCarryAJsonContentType() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok())

        resolve(clickId: "c1")

        let request = StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick).first
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.headers["Content-Type"], "application/json")
    }

    // MARK: - resolveClick

    /// The body carries the link identity and nothing else. There is no
    /// `fingerprint` key: the endpoint never read one, and sending it meant
    /// describing the user's device on a call that had no use for it.
    func testResolveBodyCarriesLinkIdentityOnly() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok())

        resolve(clickId: "c1", code: "abc")

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick).first?.body
        XCTAssertEqual(body?["click_id"] as? String, "c1")
        XCTAssertEqual(body?["code"] as? String, "abc")
        XCTAssertEqual(body?.count, 2, "the resolve body grew beyond the link identity: \(body!)")
    }

    func testResolveOmitsAbsentIdentityKeys() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok())

        resolve(clickId: nil, code: "abc")

        let body = StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick).first?.body
        XCTAssertNil(body?["click_id"])
        XCTAssertEqual(body?["code"] as? String, "abc")
    }

    /// Attribution rides the **query string**, not the body: resolving by code
    /// makes the service create the a click record, and the resolve endpoint reads
    /// UTMs off `request.GET`. It never consults the POST body.
    func testAttributionTravelsOnTheQueryStringNotTheBody() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok())

        resolve(clickId: "c1", localParams: ["utm_source": "news", "gclid": "g1"])

        let request = StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick).first
        XCTAssertEqual(request?.query["utm_source"], "news")
        XCTAssertEqual(request?.query["gclid"], "g1")
        XCTAssertNil(request?.body?["utm_source"], "attribution leaked into the body")
    }

    /// The `+` fix, end to end: `URLComponents` leaves it unencoded and the server's
    /// QueryDict decodes a bare `+` as a space, so the campaign name would
    /// arrive corrupted.
    func testPlusSignsSurviveTheRoundTrip() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok())

        resolve(clickId: "c1", localParams: ["utm_campaign": "spring+summer"])

        let request = StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick).first
        XCTAssertEqual(request?.query["utm_campaign"], "spring+summer")
    }

    func testNonAttributionParamsAreNotForwarded() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .ok())

        resolve(clickId: "c1", localParams: ["screen": "profile", "session_token": "secret"])

        let request = StubURLProtocol.waitForRequest(to: DomainConfig.resolveClick).first
        XCTAssertNil(request?.query["session_token"])
        XCTAssertNil(request?.query["screen"])
    }

    // MARK: - Response handling

    func testSuccessParsesTheJsonBody() {
        StubURLProtocol.stub(
            DomainConfig.resolveClick,
            .ok(["click_id": "c1", "params": ["utm_source": "news"]]))

        let json = resolveExpectingSuccess(clickId: "c1")

        XCTAssertEqual(json?["click_id"] as? String, "c1")
        XCTAssertEqual((json?["params"] as? [String: Any])?["utm_source"] as? String, "news")
    }

    /// A 204, or any success with nothing in it, is a success carrying an empty
    /// map — not a parse failure.
    func testAnEmptySuccessBodyParsesAsAnEmptyMap() {
        StubURLProtocol.stub(
            DomainConfig.resolveClick, StubURLProtocol.Response(status: 204, json: nil))

        XCTAssertEqual(resolveExpectingSuccess(clickId: "c1")?.count, 0)
    }

    /// Non-2xx keeps the parsed body so callers can read the service's ER_0xx
    /// code and decide whether the failure is worth retrying.
    func testHttpFailureCarriesStatusAndParsedBody() {
        StubURLProtocol.stub(
            DomainConfig.resolveClick,
            .terminal(402, ["code": "ER_011", "message": "Billing paused"]))

        let error = resolveExpectingFailure(clickId: "c1")

        guard case let NetworkError.http(status, body)? = error as? NetworkError else {
            return XCTFail("expected a NetworkError.http, got \(String(describing: error))")
        }
        XCTAssertEqual(status, 402)
        XCTAssertEqual(body["code"] as? String, "ER_011")
        XCTAssertTrue(NetworkUtils.isTerminal(error!))
    }

    func testA5xxIsReportedAsRetryable() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .transient(503))

        let error = resolveExpectingFailure(clickId: "c1")

        XCTAssertFalse(NetworkUtils.isTerminal(error!))
    }

    /// The offline case the whole retry queue exists for.
    func testTransportFailureIsReportedAsRetryable() {
        StubURLProtocol.stub(DomainConfig.resolveClick, .offline)

        let error = resolveExpectingFailure(clickId: "c1")

        XCTAssertFalse(NetworkUtils.isTerminal(error!))
    }

    /// A success whose body is not a JSON object degrades to an empty map
    /// rather than failing — the callers all read specific keys and handle
    /// their absence.
    func testAMalformedSuccessBodyDegradesToAnEmptyMap() {
        StubURLProtocol.stub(
            DomainConfig.resolveClick, StubURLProtocol.Response(status: 200, json: nil))

        XCTAssertEqual(resolveExpectingSuccess(clickId: "c1")?.count, 0)
    }

    // MARK: - Helpers

    private func resolve(
        clickId: String?, code: String? = nil, localParams: [String: String] = [:]
    ) {
        let done = expectation(description: "resolve")
        NetworkUtils.resolveClick(
            clickId: clickId, code: code, apiKey: "test-key", localParams: localParams,
            onSuccess: { _ in done.fulfill() },
            onError: { _ in done.fulfill() })
        wait(for: [done], timeout: 5)
    }

    private func resolveExpectingSuccess(clickId: String?) -> [String: Any]? {
        var result: [String: Any]?
        let done = expectation(description: "resolve succeeded")
        NetworkUtils.resolveClick(
            clickId: clickId, code: nil, apiKey: "test-key",
            onSuccess: {
                result = $0
                done.fulfill()
            },
            onError: { error in
                XCTFail("unexpected failure: \(error)")
                done.fulfill()
            })
        wait(for: [done], timeout: 5)
        return result
    }

    private func resolveExpectingFailure(clickId: String?) -> Error? {
        var result: Error?
        let done = expectation(description: "resolve failed")
        NetworkUtils.resolveClick(
            clickId: clickId, code: nil, apiKey: "test-key",
            onSuccess: { json in
                XCTFail("unexpected success: \(json)")
                done.fulfill()
            },
            onError: {
                result = $0
                done.fulfill()
            })
        wait(for: [done], timeout: 5)
        return result
    }
}
