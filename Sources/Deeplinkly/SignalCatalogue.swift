// GENERATED FILE — do not edit.
// Source: tool/signals.json
// Regenerate: dart run tool/gen_signals.dart
import Foundation

/// The lowest `AttributionLevel` at which a signal still ships.
enum SignalTier: Int {
    case minimal = 0
    case reduced = 1
    case full = 2
}

/// Where a signal comes from, and where the backend stores it.
///
/// The cases are named `staticProfile`/`dynamicSignal` rather than
/// `static`/`dynamic` because both are Swift keywords.
enum SignalScope {
    /// Collected once per device and cached until the profile stamp changes.
    case staticProfile
    /// Collected fresh at send time. Never persisted in a queue.
    case dynamicSignal
    /// Names the link or user being reported on, not the device.
    case identity
}

struct SignalSpec {
    let tier: SignalTier
    let scope: SignalScope
}

/// Every signal the SDK may send, and the level at which each is permitted.
///
/// Fail-closed by construction: `allows` returns false for any key not in
/// `specs`, at every level including `.full`. Must stay in lockstep with
/// the Kotlin twin — which is why both are generated from tool/signals.json
/// rather than maintained by hand.
enum SignalCatalogue {
    /// Part of the static-profile stamp; bumping it forces a re-collect.
    static let version = 7

    static let specs: [String: SignalSpec] = [
        "app_build_number": SignalSpec(tier: .minimal, scope: .staticProfile),
        "app_id": SignalSpec(tier: .minimal, scope: .staticProfile),
        "app_version": SignalSpec(tier: .minimal, scope: .staticProfile),
        "att_status": SignalSpec(tier: .minimal, scope: .dynamicSignal),
        "attribution_level": SignalSpec(tier: .minimal, scope: .dynamicSignal),
        "brand": SignalSpec(tier: .full, scope: .staticProfile),
        "click_id": SignalSpec(tier: .minimal, scope: .identity),
        "code": SignalSpec(tier: .minimal, scope: .identity),
        "collected_at": SignalSpec(tier: .minimal, scope: .dynamicSignal),
        "connection_type": SignalSpec(tier: .reduced, scope: .dynamicSignal),
        "cpu_type": SignalSpec(tier: .full, scope: .staticProfile),
        "custom_user_id": SignalSpec(tier: .minimal, scope: .identity),
        "deeplinkly_device_id": SignalSpec(tier: .minimal, scope: .staticProfile),
        "device_class": SignalSpec(tier: .reduced, scope: .staticProfile),
        "device_model": SignalSpec(tier: .full, scope: .staticProfile),
        "environment": SignalSpec(tier: .reduced, scope: .staticProfile),
        "fbclid": SignalSpec(tier: .reduced, scope: .identity),
        "first_app_version": SignalSpec(tier: .reduced, scope: .staticProfile),
        "first_open_at": SignalSpec(tier: .reduced, scope: .staticProfile),
        "gclid": SignalSpec(tier: .reduced, scope: .identity),
        "hardware_concurrency": SignalSpec(tier: .full, scope: .staticProfile),
        "idfa": SignalSpec(tier: .full, scope: .dynamicSignal),
        "idfv": SignalSpec(tier: .full, scope: .staticProfile),
        "install_instance_id": SignalSpec(tier: .minimal, scope: .staticProfile),
        "installed_at": SignalSpec(tier: .minimal, scope: .staticProfile),
        "ios_reported_at": SignalSpec(tier: .reduced, scope: .dynamicSignal),
        "is_emulator": SignalSpec(tier: .reduced, scope: .staticProfile),
        "is_hardware_id_real": SignalSpec(tier: .reduced, scope: .staticProfile),
        "language": SignalSpec(tier: .reduced, scope: .dynamicSignal),
        "last_opened_at": SignalSpec(tier: .minimal, scope: .dynamicSignal),
        "limit_ad_tracking": SignalSpec(tier: .reduced, scope: .dynamicSignal),
        "local_ip": SignalSpec(tier: .full, scope: .dynamicSignal),
        "locale": SignalSpec(tier: .reduced, scope: .dynamicSignal),
        "manufacturer": SignalSpec(tier: .full, scope: .staticProfile),
        "os_build_id": SignalSpec(tier: .full, scope: .staticProfile),
        "os_version": SignalSpec(tier: .reduced, scope: .staticProfile),
        "pixel_ratio": SignalSpec(tier: .full, scope: .staticProfile),
        "platform": SignalSpec(tier: .minimal, scope: .staticProfile),
        "region": SignalSpec(tier: .reduced, scope: .dynamicSignal),
        "screen_dpi": SignalSpec(tier: .full, scope: .staticProfile),
        "screen_height": SignalSpec(tier: .full, scope: .staticProfile),
        "screen_width": SignalSpec(tier: .full, scope: .staticProfile),
        "sdk_version": SignalSpec(tier: .minimal, scope: .staticProfile),
        "session_id": SignalSpec(tier: .minimal, scope: .dynamicSignal),
        "source": SignalSpec(tier: .minimal, scope: .identity),
        "static_profile_version": SignalSpec(tier: .minimal, scope: .staticProfile),
        "timezone": SignalSpec(tier: .reduced, scope: .dynamicSignal),
        "timezone_offset_min": SignalSpec(tier: .reduced, scope: .dynamicSignal),
        "ttclid": SignalSpec(tier: .reduced, scope: .identity),
        "ui_mode_night": SignalSpec(tier: .reduced, scope: .dynamicSignal),
        "unidentified_device": SignalSpec(tier: .reduced, scope: .dynamicSignal),
        "utm_campaign": SignalSpec(tier: .reduced, scope: .identity),
        "utm_content": SignalSpec(tier: .reduced, scope: .identity),
        "utm_medium": SignalSpec(tier: .reduced, scope: .identity),
        "utm_source": SignalSpec(tier: .reduced, scope: .identity),
        "utm_term": SignalSpec(tier: .reduced, scope: .identity),
        "webview_user_agent": SignalSpec(tier: .full, scope: .staticProfile),
    ]

    /// Whether `key` may be sent at `level`. Unknown keys are never sent.
    static func allows(_ key: String, at level: AttributionLevel) -> Bool {
        guard let spec = specs[key] else { return false }
        switch level {
        case .full: return true
        case .reduced: return spec.tier.rawValue <= SignalTier.reduced.rawValue
        case .minimal: return spec.tier.rawValue <= SignalTier.minimal.rawValue
        case .none: return false
        }
    }

    static func keys(for scope: SignalScope) -> Set<String> {
        Set(specs.filter { $0.value.scope == scope }.keys)
    }
}
