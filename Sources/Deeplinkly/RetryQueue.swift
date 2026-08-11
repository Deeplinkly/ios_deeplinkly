import Foundation

enum RetryQueue {
    private static let key = "dl_pending_retries"
    private static let legacyKey = "sdk_retry_queue"
    private static let maxCount = 50

    /// How long a queued payload stays worth sending.
    ///
    /// Nothing else bounds age: an item is only dropped on a terminal response,
    /// so a device that stays offline keeps a payload indefinitely and then
    /// reports its device state as current whenever it comes back.
    private static let maxItemAge: TimeInterval = 7 * 24 * 60 * 60

    // Enqueue payload for retry
    static func enqueue(type: String, payload: [String: Any]) {
        var queue = items()
        let item: [String: Any] = [
            "type": type,
            "payload": payload,
            "queued_at": Date().timeIntervalSince1970,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: item, options: []),
            let jsonString = String(data: data, encoding: .utf8)
        {
            queue.append(jsonString)
            if queue.count > maxCount { queue.removeFirst() }
            UserDefaults.standard.set(queue, forKey: key)
        }
    }

    // Get all items
    static func items() -> [String] {
        migrateLegacyQueueIfNeeded()
        return (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
    }

    /// Moves queues written by iOS SDK versions that predate cross-platform
    /// key alignment. The canonical value wins if both keys exist: that state
    /// means a previous migration wrote the new key but stopped before cleanup.
    private static func migrateLegacyQueueIfNeeded() {
        let defaults = UserDefaults.standard
        guard let legacyQueue = defaults.object(forKey: legacyKey) else { return }

        if defaults.object(forKey: key) == nil {
            defaults.set(legacyQueue, forKey: key)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    // Remove a specific item
    static func remove(_ s: String) {
        var queue = items()
        if let idx = queue.firstIndex(of: s) {
            queue.remove(at: idx)
            UserDefaults.standard.set(queue, forKey: key)
        }
    }

    /// Re-applies the current attribution level to a payload built earlier.
    ///
    /// Retry items are stored fully assembled and already filtered, so without
    /// this a level downgrade between queueing and sending would never be
    /// honoured for anything already in the queue.
    static func refilter(_ payload: [String: Any]) -> [String: Any] {
        let level = AttributionLevel.current
        return payload.filter { SignalCatalogue.allows($0.key, at: level) }
    }

    // Retry all items in queue
    static func retryAll(apiKey: String) {
        guard !TrackingPreferences.isTrackingDisabled() else { return }

        for s in items() {
            do {
                guard let data = s.data(using: .utf8),
                    let obj = try JSONSerialization.jsonObject(with: data, options: [])
                        as? [String: Any],
                    let type = obj["type"] as? String,
                    let payloadObj = obj["payload"]
                else {
                    continue
                }

                let payload: [String: Any]
                if let dict = payloadObj as? [String: Any] {
                    payload = dict
                } else if let payloadStr = payloadObj as? String,
                    let payloadData = payloadStr.data(using: .utf8),
                    let parsed = try JSONSerialization.jsonObject(with: payloadData, options: [])
                        as? [String: Any]
                {
                    payload = parsed
                } else {
                    continue
                }

                // A device offline for a month would otherwise replay
                // month-old device state as current.
                let queuedAt = obj["queued_at"] as? TimeInterval
                if let queuedAt = queuedAt,
                    Date().timeIntervalSince1970 - queuedAt > maxItemAge
                {
                    Logger.w("RetryQueue: dropping \(type) past its 7-day TTL")
                    remove(s)
                    continue
                }

                switch type {
                case "enrichment":
                    // Re-filtered against the level in force *now*. The payload
                    // was built and stored at whatever level applied when it
                    // was queued, so a user who has since moved from full to
                    // minimal would otherwise have the original full payload
                    // sent anyway. This also repairs items already in storage
                    // from an older SDK.
                    try NetworkUtils.sendEnrichmentNow(
                        payload: refilter(payload), apiKey: apiKey)
                case "error":
                    try NetworkUtils.sendErrorNow(payload: payload, apiKey: apiKey)
                case "event":
                    try NetworkUtils.sendEventNow(payload: payload, apiKey: apiKey)
                default:
                    Logger.w("RetryQueue: Unknown type \(type)")
                }

                remove(s)
            } catch {
                // A rejected payload never becomes valid, so keeping it means
                // replaying it on every launch for the life of the install.
                if NetworkUtils.isTerminal(error) {
                    Logger.w("RetryQueue: dropping item after terminal response")
                    remove(s)
                } else {
                    Logger.e("RetryQueue retry failed", error)
                }
            }
        }
    }
}
