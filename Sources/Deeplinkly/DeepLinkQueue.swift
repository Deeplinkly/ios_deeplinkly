// DeepLinkQueue.swift
import Foundation

/// Durable list of deep links that still need resolving.
///
/// Deliberately much smaller than Android's `queue/DeepLinkQueue.kt`: it exists
/// for one reason, which is that `PasteboardHandler` clears the pasteboard once
/// it has read a link. That copy is the only one — if the resolve then fails
/// (offline first launch is the common case) the install is unattributable
/// forever. Writing the entry here *before* the pasteboard is cleared makes
/// that survivable across launches.
enum DeepLinkQueue {
    private static let key = "dl_pending_resolve"
    private static let maxCount = 20
    static let maxAttempts = 5

    private static let lock = NSLock()

    struct PendingResolve {
        let clickId: String?
        let code: String?
        let uri: String
        let source: String
        var attemptCount: Int = 0

        /// Identity for dedupe and removal — the pair that gets resolved.
        var identity: String { "\(source)|\(clickId ?? "")|\(code ?? "")" }

        var asDictionary: [String: Any] {
            var out: [String: Any] = [
                "uri": uri, "source": source, "attempt_count": attemptCount,
            ]
            if let clickId = clickId { out["click_id"] = clickId }
            if let code = code { out["code"] = code }
            return out
        }

        init(clickId: String?, code: String?, uri: String, source: String, attemptCount: Int = 0) {
            self.clickId = clickId
            self.code = code
            self.uri = uri
            self.source = source
            self.attemptCount = attemptCount
        }

        init?(dictionary: [String: Any]) {
            guard let uri = dictionary["uri"] as? String,
                let source = dictionary["source"] as? String
            else { return nil }
            self.uri = uri
            self.source = source
            self.clickId = dictionary["click_id"] as? String
            self.code = dictionary["code"] as? String
            self.attemptCount = dictionary["attempt_count"] as? Int ?? 0
        }
    }

    static func all() -> [PendingResolve] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    static func enqueue(_ item: PendingResolve) {
        lock.lock()
        defer { lock.unlock() }
        var items = read()
        guard !items.contains(where: { $0.identity == item.identity }) else { return }
        items.append(item)
        if items.count > maxCount { items.removeFirst(items.count - maxCount) }
        write(items)
        Logger.d("Queued pending resolve: \(item.identity)")
    }

    static func remove(_ item: PendingResolve) {
        lock.lock()
        defer { lock.unlock() }
        write(read().filter { $0.identity != item.identity })
    }

    /// Records a failed attempt and drops the entry once it is out of budget,
    /// so an unresolvable link cannot be retried for the life of the install.
    /// Returns true when the entry is still queued.
    @discardableResult
    static func recordFailure(_ item: PendingResolve) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var items = read()
        guard let index = items.firstIndex(where: { $0.identity == item.identity }) else {
            return false
        }
        items[index].attemptCount += 1
        if items[index].attemptCount >= maxAttempts {
            Logger.w("Dropping pending resolve after \(maxAttempts) attempts: \(item.identity)")
            items.remove(at: index)
            write(items)
            return false
        }
        write(items)
        return true
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Storage

    private static func read() -> [PendingResolve] {
        let raw = (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
        return raw.compactMap { string in
            guard let data = string.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return PendingResolve(dictionary: object)
        }
    }

    private static func write(_ items: [PendingResolve]) {
        let encoded: [String] = items.compactMap { item in
            guard let data = try? JSONSerialization.data(withJSONObject: item.asDictionary),
                let string = String(data: data, encoding: .utf8)
            else { return nil }
            return string
        }
        UserDefaults.standard.set(encoded, forKey: key)
    }
}
