// SkanRegistration.swift
import Foundation

#if canImport(StoreKit)
    import StoreKit
#endif

/// Tells Apple this install is eligible for a SKAdNetwork postback.
///
/// ## Why this has to exist
///
/// Apple generates a postback only if the *advertised* app registers, and it
/// registers by calling one of two StoreKit methods on launch. Nothing else
/// substitutes: not the ad network's setup, not the
/// `NSAdvertisingAttributionReportEndpoint` key in the host app's Info.plist,
/// and not anything on our servers. Without this call there is no postback at
/// all — none to the ad network, and so none copied to the endpoint that key
/// points at.
///
/// That last point is worth stating plainly because an earlier plan got it
/// wrong: the plist key was described as "free, and it preserves the option".
/// It preserves nothing on its own. The key says *where* a copy should be sent;
/// this says *that there is anything to send*.
///
/// For a user who denied App Tracking Transparency, SKAdNetwork is the only
/// Apple-sanctioned install measurement path that exists, so on iOS this is
/// often the only attribution signal available at all.
///
/// ## What it does not do
///
/// It registers, and it does not manage conversion values. The value stays
/// unset, which Apple documents as supported: `conversion-value` is simply
/// absent from the postback while campaign, `did-win` and `redownload` still
/// arrive. That is install attribution, which is the point of registering.
///
/// A conversion-value API — the 0–63 encoding, SKAN 4.0's coarse values and
/// lock semantics, the three measurement windows — is a much larger piece of
/// work and is deliberately not here. **If it is added later, it must not let
/// this clobber it**: registering writes a fine value of 0, so a launch after
/// the host set a real value would reset it. The fix at that point is to
/// register with the current stored value rather than with 0, not to move this
/// call.
///
/// ## Consent
///
/// Gated on the local tracking opt-out and nothing else. SKAdNetwork needs no
/// ATT permission and carries no device signals — Apple aggregates and
/// thresholds the postback before anyone sees it — so the attribution level
/// does not apply: those levels gate what the SDK *observes* about a device,
/// and this observes nothing. The opt-out does apply, because registering
/// causes postbacks that would not otherwise be generated.
enum SkanRegistration {
    /// Replaces the StoreKit call in unit tests.
    ///
    /// `SKAdNetwork` cannot be exercised meaningfully off a real device with a
    /// real ad attribution, so the tests assert on *whether the SDK decided to
    /// register* — which is the part with a decision in it — rather than on
    /// StoreKit's behaviour. Same seam shape as `Keychain`'s in-memory store.
    static var registrarForTesting: (() -> Void)?

    /// Registers this install, unless the user has opted out.
    ///
    /// Safe to call more than once. Apple treats repeat calls as conversion
    /// value updates within the current measurement window rather than as new
    /// registrations, and the value being written is the one already implied.
    static func register() {
        guard !TrackingPreferences.isTrackingDisabled() else {
            Logger.d("SKAdNetwork: not registering while tracking is disabled")
            return
        }

        if let stub = registrarForTesting {
            stub()
            return
        }

        #if canImport(StoreKit)
            callStoreKit()
        #endif
    }

    #if canImport(StoreKit)
        /// Split out so the deprecated call below sits under an availability
        /// annotation rather than a warning suppression.
        private static func callStoreKit() {
            if #available(iOS 16.1, *) {
                // `registerAppForAdNetworkAttribution` is deprecated from here
                // on. Zero is the documented way to register without claiming a
                // conversion value we do not measure.
                SKAdNetwork.updatePostbackConversionValue(0) { error in
                    if let error = error {
                        Logger.w("SKAdNetwork registration failed: \(error)")
                    }
                }
            } else {
                registerLegacy()
            }
        }

        @available(iOS, introduced: 11.3, deprecated: 16.1)
        private static func registerLegacy() {
            SKAdNetwork.registerAppForAdNetworkAttribution()
        }
    #endif
}
