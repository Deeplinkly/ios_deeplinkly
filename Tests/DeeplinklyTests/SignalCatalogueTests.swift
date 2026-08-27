import XCTest

@testable import Deeplinkly

/// The generated catalogue is the single source of truth for what a consent
/// choice means, shared with Android and the backend. These tests check the
/// *rules* it encodes rather than restating the generated table — a test that
/// re-listed every key would have to be regenerated alongside it and would
/// catch nothing.
final class SignalCatalogueTests: XCTestCase {

    // MARK: - Fail-closed

    /// The property the whole design rests on: a key nobody catalogued is never
    /// sent, at any level including `.full`. A signal added to a collector but
    /// not to `tool/signals.json` is dropped rather than leaked.
    func testUnknownKeyIsRefusedAtEveryLevel() {
        for level in AttributionLevel.allCases {
            XCTAssertFalse(
                SignalCatalogue.allows("not_a_real_signal", at: level),
                "uncatalogued key leaked at \(level.rawValue)")
        }
    }

    func testEmptyKeyIsRefused() {
        XCTAssertFalse(SignalCatalogue.allows("", at: .full))
    }

    /// Key matching is exact — no prefix or case folding — so a near-miss in a
    /// collector fails closed rather than matching a neighbouring spec.
    func testKeyMatchingIsExact() {
        XCTAssertTrue(SignalCatalogue.allows("click_id", at: .full))
        XCTAssertFalse(SignalCatalogue.allows("Click_Id", at: .full))
        XCTAssertFalse(SignalCatalogue.allows("click_id ", at: .full))
        XCTAssertFalse(SignalCatalogue.allows("click", at: .full))
    }

    // MARK: - Level semantics

    func testNoneAllowsNothing() {
        for key in SignalCatalogue.specs.keys {
            XCTAssertFalse(
                SignalCatalogue.allows(key, at: .none), "\(key) survived level none")
        }
    }

    func testFullAllowsEveryCataloguedSignal() {
        for key in SignalCatalogue.specs.keys {
            XCTAssertTrue(
                SignalCatalogue.allows(key, at: .full), "\(key) blocked at level full")
        }
    }

    /// Each level is a strict subset of the one above it. This is what the
    /// doc comment on `AttributionLevel` claims and what a consent flow relies
    /// on; a tier assigned the wrong way round would break it silently.
    func testLevelsAreNestedSubsets() {
        let minimal = allowedKeys(at: .minimal)
        let reduced = allowedKeys(at: .reduced)
        let full = allowedKeys(at: .full)

        XCTAssertTrue(minimal.isSubset(of: reduced))
        XCTAssertTrue(reduced.isSubset(of: full))
        XCTAssertTrue(minimal.isStrictSubset(of: reduced), "reduced adds nothing over minimal")
        XCTAssertTrue(reduced.isStrictSubset(of: full), "full adds nothing over reduced")
        XCTAssertEqual(full.count, SignalCatalogue.specs.count)
    }

    /// The tier assigned to a spec is exactly what decides its lowest level.
    func testTierDeterminesLowestPermittedLevel() {
        for (key, spec) in SignalCatalogue.specs {
            switch spec.tier {
            case .minimal:
                XCTAssertTrue(SignalCatalogue.allows(key, at: .minimal), key)
            case .reduced:
                XCTAssertFalse(SignalCatalogue.allows(key, at: .minimal), key)
                XCTAssertTrue(SignalCatalogue.allows(key, at: .reduced), key)
            case .full:
                XCTAssertFalse(SignalCatalogue.allows(key, at: .reduced), key)
                XCTAssertTrue(SignalCatalogue.allows(key, at: .full), key)
            }
        }
    }

    // MARK: - The specific classifications that carry meaning

    /// High-entropy hardware/reporting signals must be the first thing a
    /// privacy-tier downgrade drops.
    func testHighEntropyHardwareIsFullOnly() {
        let fullOnly = [
            "screen_width", "screen_height", "screen_dpi", "pixel_ratio",
            "device_model", "manufacturer", "brand", "cpu_type",
            "hardware_concurrency", "os_build_id", "local_ip", "idfa", "idfv",
            "webview_user_agent",
        ]
        for key in fullOnly {
            XCTAssertEqual(
                SignalCatalogue.specs[key]?.tier, .full, "\(key) is not classified full")
        }
    }

    /// What survives `.minimal`: who the install is, which build, the link
    /// being reported on — plus the two keys that explain why a payload is
    /// thin. Nothing describing the device.
    func testMinimalKeepsIdentityAndSelfDescription() {
        let minimal = allowedKeys(at: .minimal)
        for key in [
            "click_id", "code", "custom_user_id", "source",
            "deeplinkly_device_id", "install_instance_id",
            "app_id", "app_version", "app_build_number", "platform", "sdk_version",
            "attribution_level", "collected_at",
        ] {
            XCTAssertTrue(minimal.contains(key), "\(key) should survive minimal")
        }
    }

    /// A payload with no signals is indistinguishable from one that was never
    /// sent, so the two keys that explain a thin payload have to outlive every
    /// downgrade that produces one.
    func testSelfDescribingKeysSurviveMinimal() {
        XCTAssertTrue(SignalCatalogue.allows("attribution_level", at: .minimal))
        XCTAssertTrue(SignalCatalogue.allows("collected_at", at: .minimal))
    }

    /// Consent state is context for everything else in the payload, so it is
    /// reported even when the payload is otherwise stripped.
    func testConsentStatusSurvivesMinimal() {
        XCTAssertTrue(SignalCatalogue.allows("att_status", at: .minimal))
    }

    func testUtmsAndAdClickIdsAreReduced() {
        for key in [
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
            "gclid", "fbclid", "ttclid",
        ] {
            XCTAssertEqual(SignalCatalogue.specs[key]?.tier, .reduced, key)
        }
    }

    // MARK: - Scopes

    /// The three scopes partition the catalogue — every spec has exactly one,
    /// and `keys(for:)` reconstructs the whole table.
    func testScopesPartitionTheCatalogue() {
        let staticKeys = SignalCatalogue.keys(for: .staticProfile)
        let dynamicKeys = SignalCatalogue.keys(for: .dynamicSignal)
        let identityKeys = SignalCatalogue.keys(for: .identity)

        XCTAssertTrue(staticKeys.isDisjoint(with: dynamicKeys))
        XCTAssertTrue(staticKeys.isDisjoint(with: identityKeys))
        XCTAssertTrue(dynamicKeys.isDisjoint(with: identityKeys))
        XCTAssertEqual(
            staticKeys.union(dynamicKeys).union(identityKeys).count,
            SignalCatalogue.specs.count)
    }

    /// Anything that can change between two sends of one install must be
    /// dynamic — a static classification would cache it and replay a stale
    /// reading as current.
    func testMutableSignalsAreDynamic() {
        for key in [
            "att_status", "idfa", "limit_ad_tracking", "connection_type",
            "locale", "language", "region", "timezone", "timezone_offset_min",
            "last_opened_at", "session_id", "ui_mode_night", "local_ip",
            "collected_at", "attribution_level", "unidentified_device",
            "ios_reported_at",
        ] {
            XCTAssertEqual(
                SignalCatalogue.specs[key]?.scope, .dynamicSignal,
                "\(key) is not classified dynamic")
        }
    }

    /// `identity` names the link or user, never the device.
    func testIdentityScopeIsLinkAndUserOnly() {
        XCTAssertEqual(
            SignalCatalogue.keys(for: .identity),
            [
                "click_id", "code", "custom_user_id", "source",
                "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
                "gclid", "fbclid", "ttclid", "gbraid", "wbraid",
            ])
    }

    // MARK: - Versioning

    /// Folded into the static-profile stamp, so a bump re-collects the profile
    /// on installs whose app version never changed. Zero or negative would be
    /// a generation bug.
    func testCatalogueVersionIsPositive() {
        XCTAssertGreaterThan(SignalCatalogue.version, 0)
    }

    private func allowedKeys(at level: AttributionLevel) -> Set<String> {
        Set(SignalCatalogue.specs.keys.filter { SignalCatalogue.allows($0, at: level) })
    }
}
