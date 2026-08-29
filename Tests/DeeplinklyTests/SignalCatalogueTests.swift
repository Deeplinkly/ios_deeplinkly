import XCTest

@testable import Deeplinkly

/// The generated catalogue is the single source of truth for what a consent
/// choice means, shared with Android and the service. These tests check the
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

    /// The four scopes partition the catalogue — every spec has exactly one,
    /// and `keys(for:)` reconstructs the whole table.
    ///
    /// Written over the whole set rather than naming the scopes pairwise, so
    /// that adding a fifth fails here instead of quietly leaving its keys out
    /// of the count.
    func testScopesPartitionTheCatalogue() {
        let byScope: [Set<String>] = [
            SignalCatalogue.keys(for: .staticProfile),
            SignalCatalogue.keys(for: .dynamicSignal),
            SignalCatalogue.keys(for: .identity),
            SignalCatalogue.keys(for: .user),
        ]

        for (i, left) in byScope.enumerated() {
            for right in byScope[(i + 1)...] {
                XCTAssertTrue(left.isDisjoint(with: right))
            }
        }
        XCTAssertEqual(
            byScope.reduce(into: Set<String>()) { $0.formUnion($1) }.count,
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

    /// Disk space is not readable on iOS, and this is not a preference.
    ///
    /// Catalogue 10 added `total_storage_gb` and `free_storage_gb` to fill the
    /// two empty slots in Meta's 16-element `extinfo` array. Both are marked
    /// Android-only in signals.json and the generator filters them out of this
    /// file — but the generator is the thing that would be changed by anyone
    /// "completing" the pair, so the constraint is asserted here as well.
    ///
    /// Every approved reason for `NSPrivacyAccessedAPICategoryDiskSpace`
    /// carries the clause that the information, or anything derived from it,
    /// may not be sent off-device. Reporting it is precisely sending it
    /// off-device. The SDK briefly reported a coarse storage tier and it was
    /// removed for this reason; the bundled privacy manifest records that.
    /// `extinfo` stays two elements short on iOS permanently.
    func testDiskSpaceIsNotInTheIosCatalogue() {
        XCTAssertNil(SignalCatalogue.specs["total_storage_gb"])
        XCTAssertNil(SignalCatalogue.specs["free_storage_gb"])
        for key in SignalCatalogue.specs.keys {
            XCTAssertFalse(
                key.contains("storage") || key.contains("disk"),
                "\(key) looks like a disk-space signal; iOS may not send one")
        }
    }

    /// `identity` names the link or user, never the device.
    /// Link identity, and nothing else.
    ///
    /// `custom_user_id` used to be here and is now `user`-scoped. That is not
    /// cosmetic: `DeepLinkQueue` derives what it persists alongside a pending
    /// resolve from this set, and used to subtract `custom_user_id` by hand to
    /// keep it out. The scope now says it, so the exclusion list is gone — and
    /// every personal field added since is kept off that queue by construction
    /// rather than by someone remembering.
    func testIdentityScopeIsLinkOnly() {
        XCTAssertEqual(
            SignalCatalogue.keys(for: .identity),
            [
                "click_id", "code", "source",
                "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
                "gclid", "fbclid", "ttclid", "gbraid", "wbraid",
                "gad_source", "gad_campaignid",
            ])
    }

    /// What the host app tells us about the person, and nothing else.
    func testUserScopeIsWhatTheAppToldUsAboutThePerson() {
        XCTAssertEqual(
            SignalCatalogue.keys(for: .user),
            [
                "custom_user_id",
                "user_email", "user_phone", "user_first_name", "user_last_name",
                "user_date_of_birth", "user_gender", "user_street", "user_city",
                "user_state", "user_zip", "user_country",
                "user_custom_data",
            ])
    }

    /// Personal data survives a REDUCED downgrade.
    ///
    /// Deliberate, and the reason it is worth pinning: the attribution levels
    /// exist to gate what we *observe* about a device, and an email the person
    /// typed into the host app is not an observation. Dropping it at REDUCED
    /// would mean a user who asked for less device tracking also silently lost
    /// the only match key their conversions have on iOS.
    func testUserDataSurvivesEveryLevelExceptNone() {
        for key in SignalCatalogue.keys(for: .user) {
            XCTAssertTrue(SignalCatalogue.allows(key, at: .minimal), key)
            XCTAssertTrue(SignalCatalogue.allows(key, at: .reduced), key)
            XCTAssertTrue(SignalCatalogue.allows(key, at: .full), key)
            XCTAssertFalse(SignalCatalogue.allows(key, at: .none), key)
        }
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
