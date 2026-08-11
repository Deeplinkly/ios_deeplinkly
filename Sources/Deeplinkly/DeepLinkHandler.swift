// DeepLinkHandler.swift
import Foundation

enum DeepLinkHandler {
    /// Matches Android's `resolveClickWithRetry(maxRetries = 2, initialDelayMs = 50)`.
    private static let maxAttempts = 3
    private static let initialRetryDelay: TimeInterval = 0.05

    /// - Parameter source: how this link reached us. "deep_link" for a Universal
    ///   Link or custom scheme, "clipboard" for the deferred pasteboard path.
    ///   The backend reads it off the enrichment payload to stamp
    ///   `ClickEvent.attribution_source` — without it a deferred iOS install is
    ///   filed as an install_referrer, which is not a thing on this platform.
    static func handle(
        url: URL,
        apiKey: String,
        source: String = "deep_link"
    ) {
        Logger.d("handle(url: \(url.absoluteString), source: \(source))")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let clickId = comps?.queryItems?.first(where: { $0.name == "click_id" })?.value
        // Only read a code off a URL that could actually be a Deeplinkly link.
        // Unguarded, this read `myapp://settings/notifications` as code
        // "notifications" — see LinkDomains.carriesShortCode.
        let code = LinkDomains.carriesShortCode(url) ? url.pathComponents.dropFirst().first : nil

        guard clickId != nil || code != nil else {
            Logger.d("No click_id, and no Deeplinkly code, in \(url.absoluteString); skipping")
            return
        }

        let pending = DeepLinkQueue.PendingResolve(
            clickId: clickId, code: code, uri: url.absoluteString, source: source
        )
        guard DeepLinkDeliveryGuard.beginIfIdle(pending.identity) else {
            Logger.d("Already resolving \(pending.identity); skipping duplicate.")
            return
        }

        // Every query parameter off the link. Two consumers: the attribution
        // subset rides along on the resolve (see NetworkUtils.resolveURL), and
        // the whole set becomes the fallback payload if the resolve never
        // answers. Computed once here rather than in the failure branch, which
        // is where it used to live — the resolve needs it too.
        let localParams: [String: String] = (comps?.queryItems ?? [])
            .reduce(into: [:]) { acc, item in
                guard let value = item.value, !value.isEmpty else { return }
                acc[item.name] = value
            }

        // Queued before the resolve starts, so a link whose resolve never
        // completes is retried on the next launch by drainPendingResolves.
        //
        // Only the pasteboard path used to enqueue, which left the failure
        // branch below calling recordFailure on an entry that was never in the
        // queue — a silent no-op. A Universal Link tapped offline therefore got
        // three in-process attempts spanning 150ms and was then abandoned to a
        // params-only fallback for the life of the install, while Android
        // retried the same link until it succeeded. Enqueueing is idempotent
        // (dedupe is on identity), and the pasteboard's own enqueue, which must
        // stay where it is because it has to happen before the clipboard is
        // cleared, now collapses into this one.
        DeepLinkQueue.enqueue(pending)

        // Link identity only. The device description is assembled by
        // EnrichmentSender at send time — a resolve can sit in the queue for
        // days, and a device snapshot taken now would be replayed then as if
        // it were current.
        var attribution: [String: String?] = [:]
        attribution["ios_reported_at"] = String(Date().timeIntervalSince1970 * 1000)
        attribution["source"] = source
        if let c = clickId {
            attribution["click_id"] = c
        } else if let c = code {
            attribution["code"] = c
        }

        // No device fingerprint is sent. /resolve reads the link identity and
        // the click-time attribution params, and nothing else — it has never
        // matched a click to an install on device signals — so building a
        // description of the user's device here shipped it for nothing.
        // Android stopped sending one first; this is the platform catching up.
        // Device signals go to /enrich, gated by AttributionLevel.
        resolveWithRetry(
            clickId: clickId, code: code, apiKey: apiKey,
            localParams: localParams, attempt: 1
        ) { result in
            defer { DeepLinkDeliveryGuard.finish(pending.identity) }
            switch result {
            case .success(let json):
                // An unknown click id comes back 200 with stale: true. Delivering
                // it would fire a deep link carrying no params at all, on every
                // cold start until the cached id was cleared.
                if NetworkUtils.isStale(json: json) {
                    Logger.w("Resolve returned a stale click; suppressing delivery.")
                    DeepLinkQueue.remove(pending)
                    return
                }

                let dartMap = NetworkUtils.extractParams(json: json, clickId: clickId)
                if let resolvedClick = dartMap["click_id"] as? String {
                    attribution["click_id"] = resolvedClick
                }

                // Persist first-touch attribution (normalized keys)
                let normalized = NetworkUtils.attributionSnapshot(
                    resolved: dartMap, source: source, fallbackClickId: clickId
                )
                AttributionStore.saveOnce(map: normalized)

                // Hand to the listener (buffered if none has attached yet). The
                // queue entry is only dropped once the link has really been
                // received — being killed while it sat in the buffer would
                // otherwise lose it, and the pasteboard copy is long gone.
                DeepLinkDeliveryGuard.markDelivered(pending.identity)
                SdkRuntime.deliverDeepLink(dartMap) {
                    DeepLinkQueue.remove(pending)
                }
                EnrichmentSender.sendOnce(
                    attributionData: attribution, source: source, apiKey: apiKey)

            case .failure(let err):
                Logger.e("resolveClick failed", err)
                NetworkUtils.reportError(
                    apiKey: apiKey, message: "resolve exception",
                    stack: err.localizedDescription)

                // A fallback delivery and a queued retry are alternatives, not
                // companions — the rule Android arrived at the hard way. Doing
                // both delivers the link twice for one tap: once immediately
                // carrying only the query params, and again when the retry
                // resolves it properly. Dart has no dedupe, so the host app
                // sees onDeepLink fire twice.
                //
                // Before this handler enqueued anything, delivering here was
                // unconditionally right for a Universal Link, because no retry
                // was coming. Now one is, so the retry owns the delivery
                // whenever it can still succeed.
                let terminal = NetworkUtils.isTerminal(err)
                if !terminal {
                    // Still queued means a later launch will resolve it
                    // properly; only an exhausted budget means this is the last
                    // word. recordFailure answers exactly that.
                    if DeepLinkQueue.recordFailure(pending) {
                        Logger.d("Resolve failed transiently; left queued for the next launch")
                        return
                    }
                    Logger.w("Resolve out of attempts; delivering fallback")
                } else {
                    // A revoked key or a suspended account will not start
                    // working on the next launch.
                    Logger.e("Resolve rejected (terminal); delivering fallback", err)
                    DeepLinkQueue.remove(pending)
                }

                // Fallback: pass the link's own query parameters through, in the
                // same {click_id, params} envelope a resolved link arrives in.
                // The whole set, not just the attribution subset the resolve
                // forwards — limiting it to the UTM keys used to drop
                // everything the link was actually addressed to (screen, id, …)
                // on the one path where the app has no other copy of it.
                let fallback = NetworkUtils.fallbackPayload(
                    clickId: clickId, localParams: localParams)
                AttributionStore.saveOnce(
                    map: NetworkUtils.attributionSnapshot(
                        resolved: fallback, source: source, fallbackClickId: clickId))
                DeepLinkDeliveryGuard.markDelivered(pending.identity)
                SdkRuntime.deliverDeepLink(fallback)
            }
        }
    }

    /// Retries the pasteboard/deep-link resolve on transient failures only.
    private static func resolveWithRetry(
        clickId: String?,
        code: String?,
        apiKey: String,
        localParams: [String: String],
        attempt: Int,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        NetworkUtils.resolveClick(
            clickId: clickId, code: code, apiKey: apiKey, localParams: localParams
        ) { json in
            completion(.success(json))
        } onError: { error in
            guard attempt < maxAttempts, !NetworkUtils.isTerminal(error) else {
                completion(.failure(error))
                return
            }
            let delay = initialRetryDelay * pow(2, Double(attempt - 1))
            Logger.d("Resolve attempt \(attempt) failed; retrying in \(delay)s")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                resolveWithRetry(
                    clickId: clickId, code: code, apiKey: apiKey,
                    localParams: localParams, attempt: attempt + 1,
                    completion: completion)
            }
        }
    }

    /// Retries links whose resolve never completed — an offline first launch
    /// after a deferred install being the case that matters, since the
    /// pasteboard copy is gone by then.
    static func drainPendingResolves(apiKey: String) {
        let pending = DeepLinkQueue.all()
        guard !pending.isEmpty else { return }
        Logger.d("Draining \(pending.count) pending resolve(s)")
        for item in pending {
            guard let url = URL(string: item.uri) else {
                DeepLinkQueue.remove(item)
                continue
            }
            handle(url: url, apiKey: apiKey, source: item.source)
        }
    }
}
