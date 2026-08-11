// DynamicSignals.swift
import Foundation
import UIKit

#if canImport(AppTrackingTransparency)
    import AppTrackingTransparency
#endif

#if canImport(AdSupport)
    import AdSupport
#endif

#if canImport(Network)
    import Network
#endif

/// The signals that can change while the app stays installed.
///
/// Collected fresh at send time, never cached and never persisted in a queue.
/// `DeepLinkQueue` can hold a pending resolve for days, and replaying a
/// snapshot of the ATT status, the network, or the clock from whenever the link
/// was first opened would report stale device state as current.
enum DynamicSignals {

    /// - Parameter staticProfile: used only to derive `unidentified_device`,
    ///   which is a statement about the payload as a whole and so cannot be
    ///   decided from the dynamic half alone.
    static func collect(staticProfile: [String: String] = [:]) -> [String: String] {
        var out: [String: String] = [:]
        let now = Date()

        // --- consent ---
        // Always reported. Whether the user has been asked, and what they said,
        // is the context that explains everything else in the payload — so it
        // survives MINIMAL for the same reason attribution_level does.
        let att = attStatus()
        out["att_status"] = att
        out["limit_ad_tracking"] = String(att != "authorized")

        let idfa = advertisingIdentifier(attStatus: att)
        out["idfa"] = idfa

        // True when we hold no durable identifier for this device at all, which
        // is a data-quality fact the backend would otherwise have to infer from
        // the absence of keys it cannot distinguish from a level downgrade.
        let hasIdfv = !(staticProfile["idfv"] ?? "").isEmpty
        out["unidentified_device"] = String(!hasIdfv && (idfa ?? "").isEmpty)

        // --- locale and clock ---
        let locale = Locale.current
        let zone = TimeZone.current

        out["locale"] = locale.identifier
        out["language"] = Locale.preferredLanguages.first ?? locale.languageCode ?? "en"
        out["region"] = locale.regionCode ?? "NA"
        out["timezone"] = zone.identifier
        out["timezone_offset_min"] = String(zone.secondsFromGMT() / 60)
        out["last_opened_at"] = iso8601(now)
        // Also stamped on every event, so a sample and the events from the same
        // visit can be joined server-side.
        out["session_id"] = SessionManager.currentSessionId(now: now)

        // --- environment ---
        out["connection_type"] = connectionType()
        out["ui_mode_night"] = String(isDarkMode())
        out["local_ip"] = localIPAddress()

        return out
    }

    // MARK: - Consent

    /// The ATT authorization status, without ever asking for it.
    ///
    /// Reading the status is not tracking and triggers no prompt. The SDK never
    /// calls `requestTrackingAuthorization` — that decision belongs to the host
    /// app, which knows where in its own flow the prompt makes sense.
    static func attStatus() -> String {
        #if canImport(AppTrackingTransparency)
            if #available(iOS 14.0, *) {
                switch ATTrackingManager.trackingAuthorizationStatus {
                case .authorized: return "authorized"
                case .denied: return "denied"
                case .restricted: return "restricted"
                case .notDetermined: return "not_determined"
                @unknown default: return "unknown"
                }
            }
        #endif
        // Before iOS 14 there was no ATT and the IDFA was available outright.
        return "not_supported"
    }

    /// Info.plist key a host app sets to opt into IDFA collection.
    private static let enableIdfaKey = "DeeplinklyEnableIDFA"

    /// Whether the host app has opted into IDFA collection.
    ///
    /// Off by default, and deliberately a *build-time* switch rather than a
    /// runtime API. Collecting the IDFA makes the containing app's privacy
    /// report declare tracking, which Apple requires an ATT prompt to justify.
    /// That is the app's decision to make and to document, not ours to make on
    /// its behalf by shipping a default.
    static var idfaEnabled: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: enableIdfaKey) else {
            return false
        }
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return (text as NSString).boolValue }
        return false
    }

    /// The IDFA, only when the user has already authorized tracking.
    ///
    /// The SDK never calls `requestTrackingAuthorization`. It reads the status
    /// the host app's own prompt produced, and reads the identifier only if
    /// that status is `authorized` — so an app that never prompts collects
    /// nothing here, which is the correct outcome rather than a bug.
    private static func advertisingIdentifier(attStatus: String) -> String? {
        guard idfaEnabled, attStatus == "authorized" else { return nil }
        #if canImport(AdSupport)
            if #available(iOS 14.0, *) {
                let identifier = ASIdentifierManager.shared().advertisingIdentifier
                // All-zeroes is what the OS returns when the IDFA is withheld.
                guard identifier.uuidString != "00000000-0000-0000-0000-000000000000" else {
                    return nil
                }
                return identifier.uuidString
            }
        #endif
        return nil
    }

    // MARK: - Environment

    /// The current connection type.
    ///
    /// `NWPathMonitor` is asynchronous by design, so a one-shot read means
    /// starting a monitor and waiting briefly for its first callback. Bounded
    /// hard: a missing `connection_type` is worth far less than a delayed send.
    private static func connectionType() -> String? {
        #if canImport(Network)
            let monitor = NWPathMonitor()
            let semaphore = DispatchSemaphore(value: 0)
            var result: String?

            monitor.pathUpdateHandler = { path in
                if path.status != .satisfied {
                    result = "none"
                } else if path.usesInterfaceType(.wifi) {
                    result = "wifi"
                } else if path.usesInterfaceType(.cellular) {
                    result = "cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    result = "ethernet"
                } else {
                    result = "other"
                }
                semaphore.signal()
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
            _ = semaphore.wait(timeout: .now() + 0.5)
            monitor.cancel()
            return result
        #else
            return nil
        #endif
    }

    private static func isDarkMode() -> Bool {
        if #available(iOS 13.0, *) {
            return UIScreen.main.traitCollection.userInterfaceStyle == .dark
        }
        return false
    }

    /// The first non-loopback IPv4 address on any up interface.
    ///
    /// Classified `full` because a LAN address is a strong correlator and,
    /// under GDPR, personal data. Best-effort: absent on a device with no
    /// network, which is fine.
    private static func localIPAddress() -> String? {
        var address: String?
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback else { continue }
            guard let addr = current.pointee.ifa_addr,
                addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            if result == 0 {
                address = String(cString: host)
                break
            }
        }
        return address
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
