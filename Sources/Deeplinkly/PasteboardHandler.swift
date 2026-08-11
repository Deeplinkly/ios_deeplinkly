// PasteboardHandler.swift
import Foundation
import UIKit

/// The deferred deep link path on iOS.
///
/// iOS has no equivalent of the Play Install Referrer API, so the only way a
/// link tapped in Safari can survive an App Store install is the pasteboard:
/// the interstitial served by `RedirectView.handle_ios` writes the link (with
/// its click id) when the visitor taps through to the store, and this reads it
/// back on first launch.
///
/// There are two ways in:
///
/// 1. **Automatic** — `check(apiKey:)` reads the pasteboard directly on
///    first launch. iOS shows its "Pasted from…" banner, but only when a
///    URL-typed item is actually there; see [hasURL]. On by default —
///    see [isCheckEnabled].
/// 2. **`UIPasteControl`** — the host app renders `DeeplinklyPasteButton`, the
///    user taps it, and iOS hands us the item **with no banner at all**. See
///    `PasteControlFactory`. Strictly the better experience where the app has
///    somewhere sensible to put a button, and it needs none of the opt-in
///    machinery below — the tap is the grant.
///
/// The two are complementary rather than alternatives: the automatic read
/// catches users who would never find a button, the control catches users
/// whose banner-shy integrator turned the automatic read off. Both are
/// once-per-install and both label their source so the arms stay comparable.
///
/// Android has no counterpart: the Play Install Referrer covers deferred
/// linking there, needs no gesture and shows nothing.
enum PasteboardHandler {
    private static let checkedKey = "deeplinkly_pasteboard_checked"
    private static let optInKey = "deeplinkly_check_pasteboard_on_install"
    private static let optInInfoKey = "DeeplinklyCheckPasteboardOnInstall"

    /// The `attribution_source` the backend records for each read path.
    ///
    /// These are the axis the two mechanisms get compared on — "the paste
    /// control recovers X% of tokens, the automatic read Y%" is not answerable
    /// unless the arms are labelled apart at the point of resolve. Must stay in
    /// step with `ClickEvent.SOURCE_CHOICES` server-side.
    private static let sourceAutomatic = "clipboard"
    private static let sourcePasteControl = "paste_control"

    /// Raw UTI strings rather than `UTType`, which would drag in
    /// UniformTypeIdentifiers (iOS 14+) and an availability guard onto a file
    /// that has to build against our iOS 12 deployment target. These
    /// identifiers are stable and predate both.
    ///
    /// `public.url` is what a `text/uri-list` clipboard write maps to, so it is
    /// both what the paste control accepts and what [readURLString] falls back
    /// to reading directly.
    private static let urlType = "public.url"
    private static let textType = "public.plain-text"

    // MARK: - Opt-in

    /// Whether the automatic (banner-showing) read is permitted.
    ///
    /// Defaults to **true**, on every supported iOS version. Set
    /// `DeeplinklyCheckPasteboardOnInstall` to `false` in Info.plist, or call
    /// `setCheckPasteboardOnInstall(false)`, to turn it off.
    ///
    /// On by default because deferred deep linking is the reason most apps
    /// integrate this SDK, and on iOS the pasteboard is the only mechanism
    /// there is — off by default meant it silently did not work for anyone who
    /// had not read the right doc page. Branch reached the same conclusion:
    /// their Flutter plugin calls `checkPasteboardOnInstall()` unless the host
    /// app sets `branch_disable_nativelink`.
    ///
    /// This briefly carried an iOS 16 floor, because the banner-free probe
    /// degraded to `hasStrings` below that and any copied text would have
    /// prompted. Dropping `hasStrings` in favour of a `hasURLs` read paired with
    /// the interstitial's `text/uri-list` write removed the asymmetry — see
    /// [hasURL] — so there is no longer a version on which defaulting this on
    /// behaves worse.
    static func isCheckEnabled() -> Bool {
        if let override = UserDefaults.standard.object(forKey: optInKey) as? Bool {
            return override
        }
        return Bundle.main.object(forInfoDictionaryKey: optInInfoKey) as? Bool ?? true
    }

    /// Enables or disables the automatic read at runtime.
    ///
    /// - Parameter runCheckNow: when enabling, perform the read immediately.
    ///   Bootstrap runs during plugin registration — before Dart can call
    ///   anything — so an app that opts in from Dart would otherwise not get a
    ///   read until the *next* launch, by which point the pasteboard has very
    ///   likely been overwritten. That is the one launch that matters.
    static func setCheckEnabled(
        _ enabled: Bool,
        apiKey: String? = nil,
        runCheckNow: Bool = true
    ) {
        UserDefaults.standard.set(enabled, forKey: optInKey)
        Logger.d("Pasteboard check on install set to \(enabled)")
        guard enabled, runCheckNow, let apiKey = apiKey else { return }
        DispatchQueue.main.async { check(apiKey: apiKey) }
    }

    /// Whether calling `check` right now would make iOS show its paste banner.
    ///
    /// Lets the host app put up a priming screen ("we can restore where you
    /// left off") before the system prompt, instead of the prompt arriving
    /// unexplained. Branch exposes the same thing as `willShowPasteboardToast`.
    ///
    /// Answers `false` when the read is disabled, already done, suppressed by
    /// tracking preferences, or when there is simply nothing URL-like to read.
    /// Reads no content and shows no banner itself.
    static func willShowBanner(completion: @escaping (Bool) -> Void) {
        guard isCheckEnabled(), !TrackingPreferences.isTrackingDisabled(),
            !Prefs.bool(for: checkedKey)
        else {
            completion(false)
            return
        }
        hasURL(completion: completion)
    }

    // MARK: - Automatic read

    static func check(apiKey: String) {
        guard !TrackingPreferences.isTrackingDisabled() else { return }

        guard isCheckEnabled() else {
            Logger.d(
                "Pasteboard check is disabled. Set \(optInInfoKey) in Info.plist or call "
                    + "setCheckPasteboardOnInstall(true) to enable deferred deep linking, or use "
                    + "DeeplinklyPasteButton for a banner-free alternative."
            )
            return
        }

        // Deferred linking is a first-launch concern. Reading on every launch
        // would show the system paste banner every time and re-deliver a link
        // the app has already handled.
        guard !Prefs.bool(for: checkedKey) else {
            Logger.d("Pasteboard already checked; skipping.")
            return
        }

        // Reading the contents is what triggers the system "Pasted from…"
        // banner, so establish there is something worth reading first.
        hasURL { hasWebURL in
            guard hasWebURL else {
                Logger.d("Pasteboard holds no URL; skipping.")
                Prefs.set(true, for: checkedKey)
                return
            }
            read(apiKey: apiKey)
        }
    }

    /// Banner-free probe for "is there a URL here". Always answers on the main
    /// queue, since both callers go on to touch UIKit.
    ///
    /// Two probes, in order, neither of which shows a banner — they inspect
    /// pasteboard *types* and patterns, never contents.
    ///
    /// 1. `hasURLs`. True when the pasteboard holds a URL-typed item
    ///    (`public.url`), which is what `RedirectView.handle_ios` writes on its
    ///    primary path: a `ClipboardItem` carrying `text/uri-list`, which WebKit
    ///    maps onto `public.url`.
    /// 2. `detectPatterns(.probableWebURL)`, iOS 16+. Covers the interstitial's
    ///    *fallback* writes, which land as plain text: `writeText` where
    ///    `ClipboardItem` is unavailable or rejects the type, `execCommand` on
    ///    Safari < 13.4, and any link copied by an interstitial predating the
    ///    `text/uri-list` change — which may sit on a user's pasteboard for as
    ///    long as it takes them to install.
    ///
    /// The second probe exists because `hasURLs` on a plain-text item depends on
    /// UIPasteboard coercing the string back into a URL, and that coercion is
    /// not dependable — the audit that first wired this up recorded `hasURLs` as
    /// *not* reliably reporting Safari's plain-text write, which is why the
    /// original implementation used pattern detection. Getting this wrong is
    /// expensive and silent: `check` marks the install checked either way, so a
    /// missed probe is one lost install with no second attempt and nothing in
    /// any log to say so.
    ///
    /// What neither probe is allowed to be is `hasStrings`, the pre-16 half of
    /// the original implementation. *Any text at all* — a copied phone number, a
    /// password, a paragraph — led to a read and therefore a banner, for content
    /// that was never ours. Below iOS 16 there is no banner-free pattern check,
    /// so those versions get `hasURLs` alone and lean on the `text/uri-list`
    /// write; that is the right side to fail on.
    ///
    /// Branch reads the pasteboard with `hasURLs` too
    /// (`BNCPasteboard.isUrlOnPasteboard`), for the same reason it works here:
    /// their interstitial writes a URL-typed item.
    private static func hasURL(completion: @escaping (Bool) -> Void) {
        let answer: (Bool) -> Void = { value in
            if Thread.isMainThread {
                completion(value)
            } else {
                DispatchQueue.main.async { completion(value) }
            }
        }

        guard !UIPasteboard.general.hasURLs else {
            answer(true)
            return
        }

        if #available(iOS 16.0, *) {
            UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                answer((try? result.get())?.contains(.probableWebURL) ?? false)
            }
            return
        }

        answer(false)
    }

    /// The banner-triggering read. Only reached once we know a URL is there.
    private static func read(apiKey: String) {
        // Mark before any parsing: a crash mid-handling must not turn into a
        // paste banner on every subsequent launch.
        Prefs.set(true, for: checkedKey)

        guard let text = readURLString() else { return }
        handle(text: text, apiKey: apiKey, source: sourceAutomatic)
    }

    /// Reads the link off the pasteboard, in three descending forms.
    ///
    /// All three are needed, and the third is not hypothetical — it was found
    /// by probing a real pasteboard rather than reasoned about:
    ///
    /// 1. `url` — an item written as a `URL` object, and also plain text that
    ///    coerces to one. Covers most cases.
    /// 2. `string` — a link from one of the interstitial's plain-text fallback
    ///    writes (`writeText`, or `execCommand` on Safari < 13.4), or from an
    ///    interstitial predating the `text/uri-list` change, which may sit on a
    ///    user's pasteboard for as long as it takes them to install.
    /// 3. The raw `public.url` item. An item carrying that UTI with a string or
    ///    data payload rather than a `URL` reports `hasURLs == true` while
    ///    **both `url` and `string` answer nil** — so without this branch the
    ///    probe would say "there is a URL here", the read would raise the
    ///    banner, and the link would be dropped on the floor. Which form a web
    ///    `ClipboardItem` produces is not ours to control, so all of them are
    ///    handled.
    ///
    /// This is one banner, not three: the prompt is raised by touching the
    /// contents at all, not once per property.
    private static func readURLString() -> String? {
        let pasteboard = UIPasteboard.general

        var candidate = pasteboard.url?.absoluteString ?? pasteboard.string
        if candidate == nil {
            if let raw = pasteboard.value(forPasteboardType: urlType) as? String {
                candidate = raw
            } else if let url = pasteboard.value(forPasteboardType: urlType) as? URL {
                candidate = url.absoluteString
            } else if let data = pasteboard.data(forPasteboardType: urlType) {
                candidate = String(data: data, encoding: .utf8)
            }
        }

        guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            Logger.w("Pasteboard reported a URL but produced no readable value")
            return nil
        }
        return text
    }

    // MARK: - UIPasteControl entry point

    /// Handles the item providers delivered by a `UIPasteControl` tap.
    ///
    /// Unlike the automatic read this shows **no banner** — the tap itself is
    /// the user's grant. Accepts both URL-typed and plain-text items: the
    /// interstitial's primary write is a `text/uri-list` item, but its
    /// `writeText` and `execCommand` fallbacks produce text, so a URL-only check
    /// (what Branch does) would miss every link that took a fallback path.
    static func handle(
        itemProviders: [NSItemProvider],
        apiKey: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard
            let provider = itemProviders.first(where: {
                $0.hasItemConformingToTypeIdentifier(urlType)
                    || $0.hasItemConformingToTypeIdentifier(textType)
            })
        else {
            Logger.d("Paste control produced no URL or text item.")
            completion(false)
            return
        }

        let finish: (String?) -> Void = { text in
            DispatchQueue.main.async {
                guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else {
                    completion(false)
                    return
                }
                let handled = handle(
                    text: text, apiKey: apiKey, source: sourcePasteControl)
                completion(handled)
            }
        }

        if provider.hasItemConformingToTypeIdentifier(urlType) {
            provider.loadItem(forTypeIdentifier: urlType, options: nil) { item, error in
                if let error = error {
                    Logger.e("Paste control failed to load URL item", error)
                }
                switch item {
                case let url as URL: finish(url.absoluteString)
                case let data as Data: finish(String(data: data, encoding: .utf8))
                case let string as String: finish(string)
                default: finish(nil)
                }
            }
            return
        }

        provider.loadItem(forTypeIdentifier: textType, options: nil) { item, error in
            if let error = error {
                Logger.e("Paste control failed to load text item", error)
            }
            switch item {
            case let string as String: finish(string)
            case let data as Data: finish(String(data: data, encoding: .utf8))
            case let url as URL: finish(url.absoluteString)
            default: finish(nil)
            }
        }
    }

    // MARK: - Shared parsing

    /// Validates a pasted string and, if it is one of ours, queues and resolves
    /// it. Returns whether it was ours.
    ///
    /// `source` is the only thing separating the two read paths once the text
    /// is in hand, so it travels with the link all the way to the backend. It
    /// also decides whether we clear the pasteboard: the automatic read took
    /// the item without being asked and cleans up after itself so the next
    /// launch does not show a second banner for a link already handled, while a
    /// paste control tap was deliberate — wiping the user's clipboard behind a
    /// gesture they made themselves is not ours to do.
    @discardableResult
    private static func handle(
        text: String,
        apiKey: String,
        source: String
    ) -> Bool {
        guard text.hasPrefix("https://") || text.hasPrefix("http://"),
            let url = URL(string: text),
            let host = url.host?.lowercased()
        else { return false }

        // Whatever the user last copied is almost never our link. Without this
        // the SDK would ship arbitrary copied URLs to the API.
        guard LinkDomains.isPasteableDomain(host) else {
            Logger.d("Pasteboard URL is not a Deeplinkly domain; ignoring.")
            return false
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let clickId = components?.queryItems?.first(where: { $0.name == "click_id" })?.value
        let code = url.pathComponents.dropFirst().first
        guard clickId != nil || code != nil else {
            Logger.d("No click_id or code on pasteboard URL; ignoring.")
            return false
        }

        // Queue before clearing — the pasteboard is the only copy of this link,
        // so an offline first launch would otherwise lose the install for good.
        let pending = DeepLinkQueue.PendingResolve(
            clickId: clickId, code: code, uri: text, source: source
        )
        DeepLinkQueue.enqueue(pending)

        // Only ours gets cleared, and only once it is safely queued.
        if source == sourceAutomatic {
            UIPasteboard.general.items = []
        }

        DeepLinkHandler.handle(url: url, apiKey: apiKey, source: source)
        return true
    }
}
