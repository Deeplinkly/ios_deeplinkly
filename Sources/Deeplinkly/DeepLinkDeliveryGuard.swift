// DeepLinkDeliveryGuard.swift
import Foundation

/// Stops one tap becoming two `onDeepLink` calls.
///
/// Lifted out of `DeepLinkHandler` unchanged so it can be tested directly —
/// the rules below were each paid for once already, and until this was its own
/// type they were reachable only through a live resolve.
///
/// Three ways one tap becomes two deliveries, and the in-flight set alone only
/// covers the first:
///
/// 1. `PasteboardHandler` queues a link and resolves it immediately while
///    `drainPendingResolves` runs the queue on the same launch. Both are in
///    flight together, so the set catches it.
/// 2. A Universal Link reaching both the application- and scene-delegate paths.
///    Usually concurrent, so usually the set catches it.
/// 3. The second arrival landing *after* the first resolve has completed — the
///    claim is released by then, so the set does not catch it, and `onDeepLink`
///    fires twice. Dart does not dedupe: the method channel handler forwards
///    straight to a broadcast stream.
///
/// (3) is why `delivered` exists. It is also why the host app may keep calling
/// `handleUniversalLink` from its own AppDelegate, which older integration
/// guides told it to do, without seeing double deliveries.
///
/// Android needs none of this: it has the intent `EXTRA_CONSUMED` extra,
/// `FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`, and a durable queue claim.
enum DeepLinkDeliveryGuard {
    /// How long a delivered link is remembered, so a second arrival of the same
    /// one is dropped rather than delivered again.
    ///
    /// Short on purpose. This exists to absorb *mechanical* double-dispatch,
    /// which lands within milliseconds; it is not meant to decide that a user
    /// who deliberately taps the same link again two minutes later should be
    /// ignored. Ten seconds covers every duplicate path above with room to
    /// spare and expires long before a deliberate re-tap.
    static let deliveredWindow: TimeInterval = 10

    private static let lock = NSLock()
    private static var inFlight: Set<String> = []
    private static var delivered: [String: Date] = [:]

    /// Claims `identity` unless it is already resolving, or was delivered
    /// inside `deliveredWindow`.
    static func beginIfIdle(_ identity: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Pruned here rather than on a timer: the map is touched only when a
        // link arrives, so there is nothing to clean up between links.
        delivered = delivered.filter { now.timeIntervalSince($0.value) < deliveredWindow }

        if delivered[identity] != nil {
            return false
        }
        return inFlight.insert(identity).inserted
    }

    /// Releases the in-flight claim. Always paired with a successful
    /// `beginIfIdle`, in a `defer`.
    static func finish(_ identity: String) {
        lock.lock()
        inFlight.remove(identity)
        lock.unlock()
    }

    /// Records that `identity` reached the listener, starting its suppression
    /// window.
    ///
    /// Called for a fallback as well as a resolved link: from the host app's
    /// point of view both are one `onDeepLink` for one tap, and the second
    /// arrival of a link we already answered with a fallback would deliver a
    /// second one.
    static func markDelivered(_ identity: String, now: Date = Date()) {
        lock.lock()
        delivered[identity] = now
        lock.unlock()
    }

    /// Drops all state. Exists for tests — nothing in the SDK clears this.
    static func reset() {
        lock.lock()
        inFlight.removeAll()
        delivered.removeAll()
        lock.unlock()
    }
}
