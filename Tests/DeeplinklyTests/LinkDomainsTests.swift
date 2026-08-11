import XCTest

@testable import Deeplinkly

/// The two questions asked of a URL: may its first path segment be read as a
/// Deeplinkly code, and may a host read off the *pasteboard* be treated as ours.
///
/// Package tests have no host app `Info.plist`, so `DeeplinklyTestSupport`
/// injects `example.deeplinkly.com`. That makes the configured branch of both
/// functions testable; the unconfigured branch remains deliberately separate.
final class LinkDomainsTests: XCTestCase {

    private let domain = DeeplinklyTestSupport.configuredDomain

    /// Guards the fixture the rest of the suite assumes.
    func testTestHostConfiguresTheExpectedDomain() {
        XCTAssertEqual(
            LinkDomains.configured(), [domain],
            "the test host's DeeplinklyLinkDomains no longer matches the fixture")
    }

    // MARK: - carriesShortCode

    func testShortCodeIsReadFromAConfiguredDomain() {
        XCTAssertTrue(LinkDomains.carriesShortCode(URL(string: "https://\(domain)/abc123")!))
    }

    func testShortCodeIsReadFromASubdomainOfAConfiguredDomain() {
        XCTAssertTrue(LinkDomains.carriesShortCode(URL(string: "https://go.\(domain)/abc")!))
    }

    func testShortCodeIsRefusedFromAnUnrelatedDomain() {
        XCTAssertFalse(LinkDomains.carriesShortCode(URL(string: "https://example.com/abc")!))
    }

    /// A substring match would accept this. Matching is exact host or a
    /// genuine subdomain, never a substring.
    func testShortCodeIsRefusedFromALookalikeDomain() {
        for hostile in [
            "https://evil.com/?x=\(domain)",
            "https://\(domain).evil.com/abc",
            "https://not\(domain)/abc",
            "https://\(domain)evil.com/abc",
        ] {
            XCTAssertFalse(
                LinkDomains.carriesShortCode(URL(string: hostile)!),
                "accepted a lookalike: \(hostile)")
        }
    }

    /// Custom schemes are out. Treating any first path segment as a code read
    /// `myapp://settings/notifications` as code "notifications", resolved it,
    /// got a 404, and the failure branch delivered a fallback — so opening an
    /// in-app screen fired `onDeepLink`. It also leaked in-app navigation paths
    /// to the API as attempted codes.
    func testCustomSchemesNeverCarryAShortCode() {
        for uri in [
            "myapp://settings/notifications",
            "myapp://\(domain)/abc",
            "deeplinkly://open?click_id=c1",
        ] {
            XCTAssertFalse(
                LinkDomains.carriesShortCode(URL(string: uri)!), "accepted scheme in \(uri)")
        }
    }

    /// Custom schemes lose nothing by this: the fallback the backend builds is
    /// `<scheme>://open?click_id=…`, matched on the click id, with no path
    /// segment to read anyway.
    func testHttpAndHttpsBothQualify() {
        XCTAssertTrue(LinkDomains.carriesShortCode(URL(string: "http://\(domain)/abc")!))
        XCTAssertTrue(LinkDomains.carriesShortCode(URL(string: "https://\(domain)/abc")!))
    }

    func testSchemeAndHostMatchingAreCaseInsensitive() {
        XCTAssertTrue(
            LinkDomains.carriesShortCode(URL(string: "HTTPS://\(domain.uppercased())/abc")!))
    }

    func testUrlWithNoHostIsRefused() {
        XCTAssertFalse(LinkDomains.carriesShortCode(URL(string: "https:///abc")!))
        XCTAssertFalse(LinkDomains.carriesShortCode(URL(string: "/just/a/path")!))
    }

    /// The question is only about the host — a link with no path is still on a
    /// link domain, and the caller is the one that finds no segment to read.
    func testAPathlessLinkStillQualifiesOnItsHost() {
        XCTAssertTrue(LinkDomains.carriesShortCode(URL(string: "https://\(domain)")!))
        XCTAssertTrue(
            LinkDomains.carriesShortCode(URL(string: "https://\(domain)/?click_id=c1")!))
    }

    // MARK: - isPasteableDomain

    /// Strict where `carriesShortCode` is permissive, and the asymmetry is the
    /// point: pasteboard content is whatever the user last copied, from
    /// anywhere, and without an allowlist the SDK would ship arbitrary copied
    /// URLs to the API.
    func testPasteableAcceptsConfiguredDomainsAndSubdomains() {
        XCTAssertTrue(LinkDomains.isPasteableDomain(domain))
        XCTAssertTrue(LinkDomains.isPasteableDomain("go.\(domain)"))
    }

    func testPasteableRefusesEverythingElse() {
        for host in [
            "example.com",
            "\(domain).evil.com",
            "not\(domain)",
            "",
        ] {
            XCTAssertFalse(LinkDomains.isPasteableDomain(host), "accepted \(host)")
        }
    }

    /// The two answers come from one matcher, so a host that may be pasted is
    /// always a host a short code may be read from. Drift between them is what
    /// putting the logic in one place was meant to prevent.
    func testPasteableHostsAlwaysCarryShortCodes() {
        for host in [domain, "go.\(domain)", "a.b.\(domain)"] {
            XCTAssertTrue(LinkDomains.isPasteableDomain(host))
            XCTAssertTrue(LinkDomains.carriesShortCode(URL(string: "https://\(host)/abc")!))
        }
    }

    func testConfiguredDomainsAreLowercasedAndTrimmed() {
        for value in LinkDomains.configured() {
            XCTAssertEqual(value, value.lowercased())
            XCTAssertEqual(value, value.trimmingCharacters(in: .whitespaces))
            XCTAssertFalse(value.isEmpty)
        }
    }
}
