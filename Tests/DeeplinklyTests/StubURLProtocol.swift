import Foundation
import XCTest

@testable import Deeplinkly

/// Intercepts every request the SDK makes, so tests can drive the network paths
/// without one packet leaving the device.
///
/// `DomainConfig` points at the production service and one customer is live on
/// an older SDK, so "just let it fail against the real host" is not an option:
/// it would be slow, non-deterministic, and pointed at production. This
/// intercepts at the `URLProtocol` layer instead — `canInit` claims *everything*,
/// so a request the test forgot to stub fails loudly rather than escaping.
///
/// Installed by replacing `NetworkUtils.session`, because `URLSession.shared`
/// ignores `protocolClasses` by design.
final class StubURLProtocol: URLProtocol {

    /// What to answer with. Defaults to an empty 200.
    struct Response {
        var status: Int = 200
        var json: [String: Any]?
        /// A transport failure — offline, DNS, timeout. Takes precedence over
        /// `status`; this is the case the retry queue exists for.
        var error: Error?

        static func ok(_ json: [String: Any] = [:]) -> Response {
            Response(status: 200, json: json)
        }

        /// A 4xx the SDK treats as terminal: it will never start succeeding.
        static func terminal(_ status: Int = 403, _ json: [String: Any] = [:]) -> Response {
            Response(status: status, json: json)
        }

        /// A failure worth retrying — a 5xx, or the transport error below.
        static func transient(_ status: Int = 503) -> Response {
            Response(status: status)
        }

        static var offline: Response {
            Response(
                error: NSError(
                    domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        }
    }

    /// One request as the SDK actually sent it.
    struct Recorded {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: [String: Any]?

        var path: String { url.path }

        /// Query parameters, which is where `/resolve` reads attribution from.
        var query: [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.reduce(into: [:]) { $0[$1.name] = $1.value }
        }
    }

    // MARK: - Installation

    private static let lock = NSLock()
    private static var responses: [String: Response] = [:]
    private static var recorded: [Recorded] = []

    /// Points `NetworkUtils` at a session this protocol serves. Call from
    /// `setUp`; always pair with `uninstall()`.
    static func install() {
        reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        NetworkUtils.session = URLSession(configuration: config)
    }

    static func uninstall() {
        NetworkUtils.session = .shared
        reset()
    }

    static func reset() {
        lock.lock()
        responses = [:]
        recorded = []
        lock.unlock()
    }

    // MARK: - Stubbing

    /// Registers the answer for an endpoint, keyed by its path so the query
    /// string does not have to be predicted.
    static func stub(_ endpoint: String, _ response: Response) {
        let path = URL(string: endpoint)?.path ?? endpoint
        lock.lock()
        responses[path] = response
        lock.unlock()
    }

    static func stubAll(_ response: Response) {
        for endpoint in [
            DomainConfig.enrich, DomainConfig.logEvent, DomainConfig.sdkError,
            DomainConfig.resolveClick, DomainConfig.generateLink,
        ] {
            stub(endpoint, response)
        }
    }

    // MARK: - Assertions

    static var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func requests(to endpoint: String) -> [Recorded] {
        let path = URL(string: endpoint)?.path ?? endpoint
        return requests.filter { $0.path == path }
    }

    /// Waits for `count` requests to the endpoint, since almost everything the
    /// SDK sends is fired from a background queue.
    @discardableResult
    static func waitForRequest(
        to endpoint: String, count: Int = 1, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) -> [Recorded] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matching = requests(to: endpoint)
            if matching.count >= count { return matching }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let matching = requests(to: endpoint)
        XCTFail(
            "expected \(count) request(s) to \(endpoint), saw \(matching.count)",
            file: file, line: line)
        return matching
    }

    /// Asserts nothing was sent to an endpoint. Settles first, so it fails on a
    /// request that was merely slow rather than passing by racing it.
    static func assertNoRequest(
        to endpoint: String, settle: TimeInterval = 0.3,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let matching = requests(to: endpoint)
        XCTAssertTrue(
            matching.isEmpty, "expected no request to \(endpoint), saw \(matching.count)",
            file: file, line: line)
    }

    // MARK: - URLProtocol

    /// Claims everything. A request with no stub is answered with a distinctive
    /// error rather than being allowed through, so an unstubbed path shows up
    /// as a test failure and never as traffic.
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: NetworkError.message("no URL"))
            return
        }

        StubURLProtocol.record(
            Recorded(
                url: url,
                method: request.httpMethod ?? "GET",
                headers: request.allHTTPHeaderFields ?? [:],
                body: StubURLProtocol.decodeBody(request)))

        StubURLProtocol.lock.lock()
        let stub = StubURLProtocol.responses[url.path]
        StubURLProtocol.lock.unlock()

        guard let stub = stub else {
            client?.urlProtocol(
                self,
                didFailWithError: NetworkError.message("unstubbed request to \(url.path)"))
            return
        }

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if let json = stub.json,
            let data = try? JSONSerialization.data(withJSONObject: json)
        {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // MARK: - Internals

    private static func record(_ request: Recorded) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    /// `URLProtocol` sees the body as a stream, not `httpBody` — URLSession
    /// converts it on the way in, so reading `httpBody` here always yields nil
    /// and every body assertion would silently pass against nothing.
    private static func decodeBody(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody

        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }

        guard let data = data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
