import Foundation

/// Payloads that failed to send, held until they can be retried.
///
/// ## Where this lives, and why it moved
///
/// The Keychain, under ``Keychain/thisDeviceOnly``, as one blob — not
/// `UserDefaults`, which is where it lived until 28 August 2026.
///
/// A queued enrichment is the whole assembled payload, and since catalogue 9
/// that payload carries whatever `setUserData` was given: email, phone, date of
/// birth, postal address. ``UserDataStore`` moved those values to the Keychain
/// precisely so they could not ride into a device backup and restore onto other
/// hardware. Queueing the same values into a `UserDefaults` plist put them
/// straight back into the store that decision was made to avoid — undoing it
/// for up to the seven days an item may sit here, on the ordinary path of a
/// send that failed because the device was briefly offline.
///
/// Stripping the user fields before queueing was the other way to close this,
/// and it would have worked: the next enrichment re-reads them from storage, so
/// nothing is lost. Keeping the payload whole was preferred, so the storage
/// moved instead of the contents.
///
/// One Keychain item holding a JSON array, rather than one item per queued
/// payload. Same reasoning as ``UserDataStore``: a single name is a single
/// thing to remember in ``PrivacyData/reset()``, and fifty of them would be
/// fifty chances to leave one behind.
///
/// ## What this costs
///
/// Keychain reads are slower than a plist read, and a full drain does one per
/// item. At the fifty-item ceiling that is still milliseconds, off the main
/// thread, and only when there is a backlog to clear.
///
/// The protection class is `AfterFirstUnlock`-based, so between a device boot
/// and the user's first unlock this store is unreadable and unwritable. An app
/// launched by a push in that window cannot queue a failed payload. The lost
/// case is one enrichment that the next one re-sends from storage anyway, which
/// is the same guarantee the discarded strip-before-queue approach rested on.
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
        guard !TrackingPreferences.isTrackingDisabled() else {
            Logger.d("RetryQueue: dropping \(type) while tracking is disabled")
            return
        }
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
            // Close the opt-out race: consent may have changed while this
            // payload was being serialized.
            guard !TrackingPreferences.isTrackingDisabled() else { return }
            write(queue)
        }
    }

    // Get all items
    static func items() -> [String] {
        migrateFromUserDefaultsIfNeeded()
        guard let raw = Keychain.get(key),
            let data = raw.data(using: .utf8),
            let queue = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return queue
    }

    /// Replaces the stored queue.
    ///
    /// A write that fails leaves the previous contents in place rather than
    /// truncating the queue, which is the safer half of the trade: a payload
    /// re-sent once is better than a payload lost.
    private static func write(_ queue: [String]) {
        guard !queue.isEmpty else {
            Keychain.delete(key)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: queue),
            let json = String(data: data, encoding: .utf8)
        else {
            Logger.w("RetryQueue: could not serialize the queue, leaving it as it was")
            return
        }
        if !Keychain.set(json, for: key, accessibility: Keychain.thisDeviceOnly) {
            // Before first unlock, or a Keychain that refused the write. The
            // payload is dropped rather than parked somewhere unprotected.
            Logger.w("RetryQueue: could not persist the queue")
        }
    }

    /// Moves a queue written before this store was the Keychain, and one
    /// written under the pre-alignment key before that.
    ///
    /// Both are drained into the Keychain rather than discarded: these are
    /// undelivered payloads, and an SDK upgrade is no reason to lose them. The
    /// `UserDefaults` copies are removed either way — leaving them is what the
    /// move was for.
    private static func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let carried = (defaults.array(forKey: key) as? [String])
            ?? (defaults.array(forKey: legacyKey) as? [String])

        // Clear the plists whether or not anything was carried over, so a
        // half-finished migration cannot leave personal data behind.
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)

        guard let carried = carried, !carried.isEmpty else { return }
        // The Keychain wins if both exist: that means a previous migration
        // already ran and these plist entries are its leftovers.
        guard Keychain.get(key) == nil else { return }
        write(carried)
    }

    // Remove a specific item
    static func remove(_ s: String) {
        var queue = items()
        if let idx = queue.firstIndex(of: s) {
            queue.remove(at: idx)
            write(queue)
        }
    }

    static func clear() {
        Keychain.delete(key)
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyKey)
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

    /// Re-filters the nested device sample without touching customer event
    /// data, which is outside the attribution signal catalogue.
    static func refilterEvent(_ payload: [String: Any]) -> [String: Any] {
        var out = payload
        guard let device = payload["device"] as? [String: Any] else { return out }
        let filtered = refilter(device)
        if filtered.isEmpty {
            out.removeValue(forKey: "device")
        } else {
            out["device"] = filtered
        }
        return out
    }

    // Retry all items in queue
    static func retryAll(apiKey: String) {
        guard !TrackingPreferences.isTrackingDisabled() else {
            clear()
            return
        }

        for s in items() {
            // Consent can change during a drain. Never dispatch the next item
            // under a state that no longer permits reporting.
            guard !TrackingPreferences.isTrackingDisabled() else {
                clear()
                return
            }
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
                    try NetworkUtils.sendEventNow(
                        payload: refilterEvent(payload), apiKey: apiKey)
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
