// SdkRuntime.swift
import Foundation

/// The single funnel every deep link delivery goes through, and the readiness
/// gate in front of it.
///
/// **Readiness.** The SDK can produce a deep link well before anything can
/// receive one: the pasteboard is read during plugin registration, which always
/// happens before `FlutterDeeplinkly.init()` has registered its `onDeepLink`
/// handler. Invoking the channel at that point drops the payload *silently* —
/// `invokeMethod` to an unhandled channel succeeds — which is why deferred deep
/// links have to be buffered until a listener attaches. Android has had this
/// since the queue rework (`core/SdkRuntime.kt`); iOS did not, so every early
/// delivery was lost.
///
/// **One funnel.** Delivery used to happen at two call sites inside
/// `DeepLinkHandler`, each holding its own `FlutterMethodChannel`. Everything
/// now goes through `deliverDeepLink`, and the channel is gone: callers hand
/// over a payload and know nothing about who receives it. That is what makes
/// the resolve path independent of Flutter, and it matches the shape Android
/// arrived at.
enum SdkRuntime {
    private struct Buffered {
        let payload: [String: Any]
        /// Runs once the payload has actually reached the listener, so callers
        /// can hold durable state — the resolve queue — until delivery is real
        /// rather than merely buffered.
        let onDelivered: (() -> Void)?
    }

    private static let lock = NSLock()
    private static var listener: DeeplinklyDeepLinkListener?
    private static var pending: [Buffered] = []

    /// Cap the buffer so a host app that never attaches a listener cannot grow
    /// it without bound. In practice it holds at most one deep link.
    private static let maxPending = 20

    /// Whether a delivery right now would reach anyone.
    static func isReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    /// Attaches the listener and flushes anything that arrived before it.
    ///
    /// Called when Dart reports it has its handler registered. Attaching a
    /// second time — a re-attach after an engine detach, or the `resumed`
    /// lifecycle event — replaces the listener and flushes again.
    static func setListener(_ listener: DeeplinklyDeepLinkListener) {
        lock.lock()
        self.listener = listener
        let flush = pending
        pending.removeAll()
        lock.unlock()

        Logger.d("Deep link listener attached; flushing \(flush.count) buffered link(s)")
        for item in flush {
            deliver(item.payload, to: listener, onDelivered: item.onDelivered)
        }
    }

    static func clearListener() {
        lock.lock()
        listener = nil
        lock.unlock()
        Logger.d("Deep link listener detached")
    }

    /// Delivers a resolved link, or buffers it until a listener attaches.
    ///
    /// - Parameter onDelivered: called once the payload has reached the
    ///   listener — never before. `DeepLinkHandler` drops the durable queue
    ///   entry inside it, so running it early would discard a link that has not
    ///   arrived, and the pasteboard copy is long gone by then.
    static func deliverDeepLink(_ payload: [String: Any], onDelivered: (() -> Void)? = nil) {
        lock.lock()
        let target = listener
        if target == nil {
            if pending.count >= maxPending { pending.removeFirst() }
            pending.append(Buffered(payload: payload, onDelivered: onDelivered))
        }
        lock.unlock()

        guard let target = target else {
            Logger.w("No deep link listener attached; buffered the link")
            return
        }
        deliver(payload, to: target, onDelivered: onDelivered)
    }

    /// The main-thread hop, and the only place `onDelivered` is run.
    ///
    /// `onDelivered` fires *after* the listener has been called, not alongside
    /// the dispatch. It used to run synchronously while the delivery itself was
    /// dispatched async, so a link resolved off the main thread — which is
    /// every link, since resolves complete on a URLSession queue — had its
    /// queue entry dropped before it had actually been handed to anyone.
    /// Android's funnel has always ordered these correctly.
    private static func deliver(
        _ payload: [String: Any],
        to listener: DeeplinklyDeepLinkListener,
        onDelivered: (() -> Void)?
    ) {
        let send = {
            listener.onDeepLink(payload)
            Logger.d("Delivered deep link")
            onDelivered?()
        }

        if Thread.isMainThread {
            send()
        } else {
            DispatchQueue.main.async(execute: send)
        }
    }
}
