// DeeplinklyDeepLinkListener.swift
import Foundation

/// Where the SDK delivers a resolved deep link.
///
/// The single seam between resolving a link and whatever is waiting for one.
/// The Flutter plugin implements this over its method channel; a native
/// integrator implements it directly. Nothing behind this protocol knows
/// Flutter exists — which is what lets `DeepLinkHandler`, `PasteboardHandler`
/// and `SdkRuntime` move into a native SDK unchanged.
///
/// Mirrors Android's `DeeplinklyDeepLinkListener`, which is what let the same
/// files there drop their `MethodChannel` parameter and extract cleanly.
public protocol DeeplinklyDeepLinkListener: AnyObject {
    /// - Parameter payload: the `{click_id, params, probability}` envelope,
    ///   forwarded exactly as it was resolved. The typed accessors read from
    ///   this map; parsing and re-serialising it would put a lossy round trip
    ///   in the one path that has to be exact.
    ///
    /// Always called on the main thread — `SdkRuntime` guarantees it, because
    /// both the Flutter channel and any UIKit a native listener touches require
    /// it.
    func onDeepLink(_ payload: [String: Any])
}
