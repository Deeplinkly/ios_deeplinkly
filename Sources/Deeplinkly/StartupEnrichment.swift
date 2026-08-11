// StartupEnrichment.swift
import Foundation

enum StartupEnrichment {
    private static let lock = NSLock()
    private static var sentThisProcess = false

    private static let timeout: TimeInterval = 30

    static func schedule(apiKey: String) {
        lock.lock()
        guard !sentThisProcess else {
            lock.unlock()
            return
        }
        sentThisProcess = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let ready = waitUntilAttribution(timeout: timeout)
            if !ready {
                // Send anyway, as Android does. A device that never resolved a
                // link is still a real install, and dropping the payload meant
                // it never appeared at all.
                Logger.d("StartupEnrichment: no attribution within \(timeout)s; sending anyway")
            }
            // Only the first-touch attribution is passed. The device half is
            // assembled inside the sender, fresh, at send time.
            var attribution: [String: String?] = [:]
            for (k, v) in AttributionStore.get() { attribution[k] = v as? String }
            EnrichmentSender.sendOnce(
                attributionData: attribution, source: "app_start", apiKey: apiKey,
                force: !ready)
            Logger.d("StartupEnrichment: sent.")
        }
    }

    /// Attribution can land at any point during launch — the pasteboard resolve
    /// in particular is a network round trip — so this waits for it rather than
    /// racing it.
    private static func waitUntilAttribution(timeout: TimeInterval) -> Bool {
        if hasAttributionData(AttributionStore.get()) { return true }

        let semaphore = DispatchSemaphore(value: 0)
        let token = AttributionStore.addListener { attribution in
            if hasAttributionData(attribution) { semaphore.signal() }
        }
        defer { AttributionStore.removeListener(token) }

        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    /// Mirrors Android's `hasAttributionData`. click_id and code count: a
    /// deferred link often resolves to a click id with no UTMs on it at all,
    /// and omitting them here meant the wait always timed out.
    private static func hasAttributionData(_ attr: [String: Any]) -> Bool {
        let keys = ["click_id", "code", "utm_source", "gclid", "fbclid", "ttclid"]
        return keys.contains { !((attr[$0] as? String) ?? "").isEmpty }
    }
}
