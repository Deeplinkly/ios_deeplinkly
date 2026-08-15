import XCTest

@testable import Deeplinkly

/// The pure half of `NetworkUtils`: response interpretation and payload
/// shaping. Everything here decides what the app is told a link means, so a
/// mistake shows up as wrong attribution rather than as a failure.
///
/// The request-issuing half is not covered — see `SEAM_TESTS.md`.
final class NetworkUtilsTests: XCTestCase {

    // MARK: - isStale

    /// /resolve answers an unknown click id with HTTP 200 and `stale: true`
    /// rather than a 404, so this flag is the only signal that nothing was
    /// resolved. Missing it delivers an empty deep link on every cold start.
    func testIsStaleReadsTheFlag() {
        XCTAssertTrue(NetworkUtils.isStale(json: ["stale": true]))
        XCTAssertFalse(NetworkUtils.isStale(json: ["stale": false]))
        XCTAssertFalse(NetworkUtils.isStale(json: [:]))
    }

    /// `JSONSerialization` hands booleans back as `NSNumber`, so the plain
    /// `as? Bool` cast is not enough on its own.
    func testIsStaleAcceptsNumericBooleans() {
        XCTAssertTrue(NetworkUtils.isStale(json: ["stale": NSNumber(value: true)]))
        XCTAssertTrue(NetworkUtils.isStale(json: ["stale": 1]))
        XCTAssertFalse(NetworkUtils.isStale(json: ["stale": 0]))
    }

    func testIsStaleIgnoresUnrelatedTypes() {
        XCTAssertFalse(NetworkUtils.isStale(json: ["stale": "true"]))
        XCTAssertFalse(NetworkUtils.isStale(json: ["stale": NSNull()]))
    }

    // MARK: - extractParams

    func testExtractParamsBuildsTheEnvelope() {
        let out = NetworkUtils.extractParams(
            json: ["click_id": "server-1", "params": ["utm_source": "news"]],
            clickId: "server-1")

        XCTAssertEqual(out["click_id"] as? String, "server-1")
        XCTAssertEqual((out["params"] as? [String: Any])?["utm_source"] as? String, "news")
    }

    /// The requested id wins over the body's, so a probabilistic match does not
    /// rewrite the id the app asked about.
    func testExtractParamsPrefersTheRequestedClickId() {
        let out = NetworkUtils.extractParams(
            json: ["click_id": "server-1"], clickId: "requested-1")
        XCTAssertEqual(out["click_id"] as? String, "requested-1")
    }

    func testExtractParamsFallsBackToTheResponseClickId() {
        let out = NetworkUtils.extractParams(json: ["click_id": "server-1"], clickId: nil)
        XCTAssertEqual(out["click_id"] as? String, "server-1")
    }

    /// On a stale response the id must come from the body — where it is null —
    /// and never from what was asked, or a stale click is reported as live.
    func testExtractParamsRefusesToReviveAStaleClickId() {
        let out = NetworkUtils.extractParams(
            json: ["stale": true, "click_id": NSNull()], clickId: "requested-1")
        XCTAssertTrue(out["click_id"] is NSNull)
    }

    func testExtractParamsUsesNullWhenNoIdIsAvailable() {
        let out = NetworkUtils.extractParams(json: [:], clickId: nil)
        XCTAssertTrue(out["click_id"] is NSNull)
    }

    /// Absent keys are omitted rather than sent as null — Dart reads presence.
    func testExtractParamsOmitsAbsentParams() {
        let out = NetworkUtils.extractParams(json: ["click_id": "c1"], clickId: "c1")
        XCTAssertNil(out["params"])
        XCTAssertEqual(out.count, 1)
    }

    func testExtractParamsIgnoresMalformedParams() {
        let out = NetworkUtils.extractParams(
            json: ["click_id": "c1", "params": "not a dictionary"], clickId: "c1")
        XCTAssertNil(out["params"])
    }

    // MARK: - fallbackPayload

    /// The fallback keeps the same `{click_id, params}` envelope a resolved
    /// link arrives in. A flat map was invisible to any app written against a
    /// resolved link — the link arrived carrying nothing readable.
    func testFallbackPayloadUsesTheResolvedEnvelope() {
        let out = NetworkUtils.fallbackPayload(
            clickId: "c1", localParams: ["utm_source": "news", "screen": "profile"])

        XCTAssertEqual(out["click_id"] as? String, "c1")
        let params = out["params"] as? [String: String]
        XCTAssertEqual(params?["utm_source"], "news")
        XCTAssertEqual(params?["screen"], "profile")
    }

    /// Unlike the resolve, the fallback forwards *every* query parameter: it is
    /// the one path where the app has no other copy of what the link was
    /// addressed to.
    func testFallbackPayloadKeepsNonAttributionParams() {
        let out = NetworkUtils.fallbackPayload(
            clickId: nil, localParams: ["screen": "profile", "id": "42"])
        XCTAssertEqual(Set((out["params"] as? [String: String] ?? [:]).keys), ["screen", "id"])
    }

    /// `click_id` is the envelope's own key; repeating it inside `params` would
    /// have Dart read the same value from two places.
    func testFallbackPayloadStripsClickIdFromParams() {
        let out = NetworkUtils.fallbackPayload(
            clickId: "c1", localParams: ["click_id": "c1", "utm_source": "news"])
        XCTAssertNil((out["params"] as? [String: String])?["click_id"])
    }

    func testFallbackPayloadUsesNullForMissingClickId() {
        let out = NetworkUtils.fallbackPayload(clickId: nil, localParams: [:])
        XCTAssertTrue(out["click_id"] is NSNull)
        XCTAssertTrue((out["params"] as? [String: String])?.isEmpty ?? false)
    }

    // MARK: - attributionQuery

    /// Only the keys the backend reads. The link's other query parameters are
    /// the host app's own data and have no business being recorded against the
    /// click.
    func testAttributionQueryKeepsOnlyCataloguedKeys() {
        let out = NetworkUtils.attributionQuery([
            "utm_source": "news", "utm_medium": "email", "utm_campaign": "spring",
            "utm_term": "shoes", "utm_content": "hero",
            "gclid": "g1", "fbclid": "f1", "ttclid": "t1",
            "screen": "profile", "session_token": "secret",
        ])

        XCTAssertEqual(
            Set(out.keys),
            [
                "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
                "gclid", "fbclid", "ttclid",
            ])
        XCTAssertNil(out["session_token"])
    }

    func testAttributionQueryDropsEmptyValues() {
        let out = NetworkUtils.attributionQuery(["utm_source": "", "utm_medium": "email"])
        XCTAssertEqual(Set(out.keys), ["utm_medium"])
    }

    func testAttributionQueryOnEmptyInputIsEmpty() {
        XCTAssertTrue(NetworkUtils.attributionQuery([:]).isEmpty)
    }

    // MARK: - resolveURL

    /// Attribution rides the query string because `create_click_event` reads it
    /// off `request.GET`; the POST body is parsed only for `click_id` and
    /// `code`. Sending them in the body looks right and drops every one.
    func testResolveURLCarriesAttributionOnTheQueryString() {
        let url = NetworkUtils.resolveURL(localParams: ["utm_source": "news"])
        XCTAssertTrue(url.hasPrefix(DomainConfig.resolveClick))
        XCTAssertTrue(url.contains("utm_source=news"))
    }

    func testResolveURLIsBareWhenThereIsNoAttribution() {
        XCTAssertEqual(NetworkUtils.resolveURL(localParams: [:]), DomainConfig.resolveClick)
        XCTAssertEqual(
            NetworkUtils.resolveURL(localParams: ["screen": "profile"]),
            DomainConfig.resolveClick,
            "a non-attribution param should not produce a query string")
    }

    /// Dictionary order is not stable, so the parameters are sorted — an
    /// unstable URL is untestable and defeats any caching in between.
    func testResolveURLIsDeterministic() {
        let params = ["utm_source": "news", "gclid": "g1", "utm_medium": "email"]
        let first = NetworkUtils.resolveURL(localParams: params)
        for _ in 0..<20 {
            XCTAssertEqual(NetworkUtils.resolveURL(localParams: params), first)
        }
        XCTAssertTrue(
            first.contains("gclid=g1&utm_medium=email&utm_source=news"),
            "parameters are not in sorted order: \(first)")
    }

    /// `URLComponents` leaves "+" unencoded and Django's QueryDict decodes a
    /// bare "+" as a space, so `utm_campaign=a+b` would arrive as "a b" —
    /// silent corruption of the field this whole method exists to deliver.
    func testResolveURLEncodesPlusSigns() {
        let url = NetworkUtils.resolveURL(localParams: ["utm_campaign": "spring+summer"])
        XCTAssertTrue(url.contains("utm_campaign=spring%2Bsummer"), url)
        XCTAssertFalse(url.contains("spring+summer"), url)
    }

    /// A raw space or a bare "&" in a value would truncate the query or split
    /// it into a parameter the backend never expected.
    func testResolveURLPercentEncodesReservedCharacters() {
        let url = NetworkUtils.resolveURL(localParams: ["utm_campaign": "spring sale&more"])
        XCTAssertFalse(url.contains("spring sale"), "a raw space reached the URL: \(url)")
        XCTAssertTrue(url.contains("%26"), "a bare ampersand reached the URL: \(url)")
        XCTAssertNotNil(URLComponents(string: url), "the URL does not parse: \(url)")
    }

    /// The values survive the encoding intact — the point is to deliver them,
    /// not merely to escape them.
    func testResolveURLValuesDecodeBackToTheirOriginals() {
        let params = ["utm_campaign": "spring+summer", "utm_source": "news letter"]
        let url = NetworkUtils.resolveURL(localParams: params)

        let components = URLComponents(string: url)
        let decoded = (components?.queryItems ?? []).reduce(into: [String: String]()) {
            $0[$1.name] = $1.value
        }
        XCTAssertEqual(decoded["utm_campaign"], "spring+summer")
        XCTAssertEqual(decoded["utm_source"], "news letter")
    }

    // MARK: - attributionSnapshot

    /// The backend nests UTMs inside "params". Reading them off the top level
    /// always yielded nil, so every stored snapshot carried nothing but a
    /// source and a click id.
    func testAttributionSnapshotUnwrapsNestedParams() {
        let snapshot = NetworkUtils.attributionSnapshot(
            resolved: [
                "click_id": "c1",
                "params": ["utm_source": "news", "gclid": "g1"],
            ],
            source: "deep_link")

        XCTAssertEqual(snapshot["source"] ?? nil, "deep_link")
        XCTAssertEqual(snapshot["click_id"] ?? nil, "c1")
        XCTAssertEqual(snapshot["utm_source"] ?? nil, "news")
        XCTAssertEqual(snapshot["gclid"] ?? nil, "g1")
    }

    func testAttributionSnapshotFallsBackToTheRequestedClickId() {
        let snapshot = NetworkUtils.attributionSnapshot(
            resolved: ["params": [:]], source: "clipboard", fallbackClickId: "c1")
        XCTAssertEqual(snapshot["click_id"] ?? nil, "c1")
    }

    func testAttributionSnapshotPrefersTheResolvedClickId() {
        let snapshot = NetworkUtils.attributionSnapshot(
            resolved: ["click_id": "resolved"], source: "deep_link", fallbackClickId: "requested")
        XCTAssertEqual(snapshot["click_id"] ?? nil, "resolved")
    }

    /// Values arrive from JSON, so they are not necessarily strings.
    func testAttributionSnapshotCoercesNonStringValues() {
        let snapshot = NetworkUtils.attributionSnapshot(
            resolved: ["params": ["utm_campaign": 42]], source: "deep_link")
        XCTAssertEqual(snapshot["utm_campaign"] ?? nil, "42")
    }

    func testAttributionSnapshotTreatsNullAndEmptyAsAbsent() {
        let snapshot = NetworkUtils.attributionSnapshot(
            resolved: ["params": ["utm_source": NSNull(), "utm_medium": ""]],
            source: "deep_link")
        XCTAssertNil(snapshot["utm_source"] ?? nil)
        XCTAssertNil(snapshot["utm_medium"] ?? nil)
    }

    /// Absent attribution keys are *removed*, not stored as present nils.
    ///
    /// This is Swift's subscript semantics rather than an explicit choice: on a
    /// `[String: String?]`, `out[key] = nil` deletes the entry, so the loop's
    /// `out[key] = nil` branch drops the key entirely. The dictionary literal
    /// that seeds `source` and `click_id` does not go through the subscript, so
    /// those two survive as present nils — hence the asymmetry below.
    ///
    /// It makes no difference to today's only consumer (`AttributionStore
    /// .saveOnce` compacts the map before storing it), which is why it has
    /// never mattered. It is pinned here because a reader "tidying" the loop
    /// into `updateValue(nil, forKey:)` during the extraction would change the
    /// shape without changing a line of visible logic.
    func testAttributionSnapshotOmitsAbsentAttributionKeys() {
        let snapshot = NetworkUtils.attributionSnapshot(resolved: [:], source: "app_start")

        XCTAssertEqual(snapshot["source"] ?? nil, "app_start")
        for key in [
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
            "gclid", "fbclid", "ttclid",
        ] {
            XCTAssertFalse(
                snapshot.keys.contains(key), "\(key) is present despite having no value")
        }
    }

    /// The seeded keys behave the other way round — present, carrying nil.
    func testAttributionSnapshotAlwaysCarriesSourceAndClickId() {
        let snapshot = NetworkUtils.attributionSnapshot(resolved: [:], source: "app_start")
        XCTAssertTrue(snapshot.keys.contains("source"))
        XCTAssertTrue(snapshot.keys.contains("click_id"))
        XCTAssertNil(snapshot["click_id"] ?? nil)
    }

    /// Whatever the shape, the map compacts to only the keys that carry a
    /// value — which is what `AttributionStore` actually persists.
    func testAttributionSnapshotCompactsToPopulatedKeysOnly() {
        let snapshot = NetworkUtils.attributionSnapshot(
            resolved: ["click_id": "c1", "params": ["utm_source": "news"]],
            source: "deep_link")
        XCTAssertEqual(
            Set(snapshot.compactMapValues { $0 }.keys),
            ["source", "click_id", "utm_source"])
    }

    /// The fallback path stores a snapshot too, built from `fallbackPayload`,
    /// so the two shapes have to compose.
    func testAttributionSnapshotReadsAFallbackPayload() {
        let fallback = NetworkUtils.fallbackPayload(
            clickId: "c1", localParams: ["utm_source": "news", "screen": "profile"])
        let snapshot = NetworkUtils.attributionSnapshot(
            resolved: fallback, source: "deep_link", fallbackClickId: "c1")

        XCTAssertEqual(snapshot["click_id"] ?? nil, "c1")
        XCTAssertEqual(snapshot["utm_source"] ?? nil, "news")
        XCTAssertNil(snapshot["screen"] ?? nil, "a non-attribution param leaked into the snapshot")
    }

    // MARK: - NetworkError

    /// Terminal means "will not start succeeding on retry". Queueing one
    /// replays it on every launch for the life of the install.
    func testTerminalClassificationByStatus() {
        let terminal = [400, 401, 402, 403, 404, 422, 499]
        let retryable = [408, 429, 500, 502, 503, 504, 200, 301]

        for status in terminal {
            XCTAssertTrue(
                NetworkUtils.isTerminal(NetworkError.http(status: status, body: [:])),
                "\(status) should be terminal")
        }
        for status in retryable {
            XCTAssertFalse(
                NetworkUtils.isTerminal(NetworkError.http(status: status, body: [:])),
                "\(status) should be retryable")
        }
    }

    /// 408 and 429 are the two 4xx exceptions — both transient and worth
    /// backing off on rather than dropping.
    func testTimeoutAndRateLimitAreRetryable() {
        XCTAssertFalse(NetworkError.http(status: 408, body: [:]).isTerminal)
        XCTAssertFalse(NetworkError.http(status: 429, body: [:]).isTerminal)
    }

    /// A transport failure — offline, DNS, timeout — is the case the retry
    /// queue exists for, so it must never read as terminal.
    func testTransportFailuresAreNotTerminal() {
        XCTAssertFalse(NetworkUtils.isTerminal(NetworkError.message("Bad URL")))
        XCTAssertFalse(
            NetworkUtils.isTerminal(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
    }

    func testErrorDescriptionSurfacesTheBackendMessage() {
        XCTAssertEqual(
            NetworkError.http(status: 402, body: ["message": "Billing paused"]).errorDescription,
            "HTTP 402: Billing paused")
        XCTAssertEqual(
            NetworkError.http(status: 403, body: ["error": "Revoked"]).errorDescription,
            "HTTP 403: Revoked")
        XCTAssertEqual(
            NetworkError.http(status: 500, body: [:]).errorDescription, "HTTP 500")
        XCTAssertEqual(NetworkError.message("Bad URL").errorDescription, "Bad URL")
    }
}
