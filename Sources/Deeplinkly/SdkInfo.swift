// SdkInfo.swift
import Foundation

/// Identity of the SDK build itself.
///
/// Hand-maintained rather than read from the bundle: `CFBundleShortVersionString`
/// in a static library resolves to the *host app's* version, not ours. Bump
/// `version` with pubspec.yaml and the podspec.
///
/// Reported as `sdk_version` and folded into the static-profile stamp, so an SDK
/// upgrade re-collects the device profile — which is what makes a signal added
/// in a new release actually get collected on existing installs.
enum SdkInfo {
    static let version = "1.9.0"
    static let platform = "ios"

    /// Monotonic reference captured when the SDK initialised, held in memory only.
    ///
    /// Events report `elapsedSinceInit()` — milliseconds since this point —
    /// rather than a raw `systemUptime` reading. The delta is what orders
    /// events from a device whose wall clock is wrong; the absolute reading
    /// additionally revealed how long the device had been booted, which is a
    /// device correlator we have no use for.
    ///
    /// This also puts the `35F9.1` required-reason declaration on its strongest
    /// footing: that reason permits reading boot time "to measure the amount of
    /// time that has elapsed between events that occurred within the app",
    /// which is now exactly and only what the value is used for.
    private static let initUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    /// Milliseconds since the SDK initialised in this process.
    static func elapsedSinceInit() -> Int {
        Int((ProcessInfo.processInfo.systemUptime - initUptime) * 1000)
    }
}
