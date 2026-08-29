// LinkDomains.swift
import Foundation

/// The host app's Deeplinkly link domains, and the two questions asked of them.
///
/// Both readers used to answer their own version of "is this one of ours".
/// `PasteboardHandler` had an allowlist; `DeepLinkHandler` had nothing at all
/// and read the first path segment of *any* URL as a Deeplinkly code. Android
/// has had the second rule since `carriesShortCode`, and this is the platform
/// catching up — with the matching logic in one place so the two answers cannot
/// drift apart again.
///
/// Configured as a `DeeplinklyLinkDomains` string array in Info.plist:
///
/// ```xml
/// <key>DeeplinklyLinkDomains</key>
/// <array><string>links.example.com</string></array>
/// ```
enum LinkDomains {
    private static let infoKey = "DeeplinklyLinkDomains"

    /// Used only by the pasteboard reader; see `isPasteableDomain`.
    private static let defaultDomain = "deeplinkly.com"

    /// Test seam for package tests, which have no host application's
    /// `Info.plist`. Production never sets this and reads `Bundle.main`.
    static var configuredDomainsOverride: [String]?

    /// The configured domains, lowercased and trimmed. Empty when unset.
    ///
    /// Read on every call rather than cached: `Bundle.main` lookups are cheap
    /// and hit at most twice per link, and a cache here would be one more piece
    /// of state to invalidate in tests for no measurable gain.
    static func configured() -> [String] {
        let raw = configuredDomainsOverride
            ?? (Bundle.main.object(forInfoDictionaryKey: infoKey) as? [String])
            ?? []
        return raw
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Exact host, or a subdomain of a listed domain.
    ///
    /// Deliberately not a substring match — that would accept
    /// `evil.com/?x=deeplinkly.com`.
    private static func matches(_ host: String, against domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// Whether this URI's first path segment may be read as a Deeplinkly code.
    ///
    /// A link that came through the redirect always carries a `click_id`, so
    /// the code is only ever needed for the App Link / Universal Link bypass:
    /// the OS routing `https://<link domain>/<code>` straight to the app, which
    /// means the service never saw the click and has no a click record for it yet.
    ///
    /// Treating *any* first path segment as a code — which is what iOS used to
    /// do — meant every URL the app opened was resolved against the service.
    /// For an app with its own custom-scheme routes,
    /// `myapp://settings/notifications` was resolved as code "notifications",
    /// came back 404, and the failure branch delivers a fallback: opening an
    /// in-app screen fired `onDeepLink` carrying a URL that had nothing to do
    /// with Deeplinkly. It also leaked in-app navigation paths to the API as
    /// attempted codes.
    ///
    /// Custom schemes are therefore out, and they lose nothing — the fallback
    /// the service builds is `<scheme>://open?click_id=…`, which is matched on
    /// the click id and has no path segment to read anyway.
    ///
    /// Permissive when no domains are configured, matching Android: the URL
    /// already reached us through the OS, so rejecting a real link is worse
    /// than a spurious resolve. An app that Universal Links its marketing site
    /// alongside its link domain wants them set.
    static func carriesShortCode(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        let domains = configured()
        return domains.isEmpty || matches(host, against: domains)
    }

    /// Whether a host read off the *pasteboard* may be treated as ours.
    ///
    /// Strict where `carriesShortCode` is permissive, and the asymmetry is the
    /// point: this content is whatever the user last copied, from anywhere,
    /// and without an allowlist the SDK would ship arbitrary copied URLs to the
    /// API. An unconfigured app falls back to the Deeplinkly domain rather than
    /// to "anything", and says so.
    static func isPasteableDomain(_ host: String) -> Bool {
        var domains = configured()
        if domains.isEmpty {
            Logger.w(
                "\(infoKey) is not set in Info.plist; only \(defaultDomain) links "
                    + "will be recognised. Add your link domain to enable deferred deep linking."
            )
            domains = [defaultDomain]
        }
        return matches(host, against: domains)
    }
}
