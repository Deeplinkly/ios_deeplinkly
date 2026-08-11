import XCTest

@testable import Deeplinkly

/// The static half of the device description: hardware, app build, install
/// provenance. Collected once and cached until the stamp changes.
final class DeviceProfileTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
    }

    override func tearDown() {
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    // MARK: - Contents

    /// The signals that identify the install and the build. A profile missing
    /// one of these produces an enrichment the backend cannot file.
    func testProfileCarriesIdentityAndBuild() {
        let profile = DeviceProfile.current()

        for key in [
            "deeplinkly_device_id", "install_instance_id", "platform", "sdk_version",
            "static_profile_version", "app_id", "app_version",
        ] {
            XCTAssertNotNil(profile[key], "\(key) missing from the static profile")
            XCTAssertFalse((profile[key] ?? "").isEmpty, "\(key) is empty")
        }
    }

    func testProfileReportsThisPlatformAndSdkVersion() {
        let profile = DeviceProfile.current()
        XCTAssertEqual(profile["platform"], "ios")
        XCTAssertEqual(profile["sdk_version"], SdkInfo.version)
    }

    func testProfileCarriesHardwareDescription() {
        let profile = DeviceProfile.current()
        XCTAssertEqual(profile["manufacturer"], "Apple")
        XCTAssertEqual(profile["brand"], "Apple")
        XCTAssertNotNil(profile["device_class"])
        XCTAssertNotNil(profile["screen_width"])
        XCTAssertNotNil(profile["screen_height"])
        XCTAssertNotNil(profile["hardware_concurrency"])
    }

    /// `device_model` is the hardware identifier ("iPhone15,2"), not
    /// `UIDevice.model`, which returns the family string "iPhone" for every
    /// iPhone ever made and is what this field used to carry.
    func testDeviceModelIsTheHardwareIdentifierNotTheFamily() {
        let model = DeviceProfile.current()["device_model"]
        XCTAssertNotNil(model)
        XCTAssertNotEqual(model, "iPhone", "device_model regressed to the family string")
        XCTAssertNotEqual(model, "iPad")
        // On the simulator this is read from SIMULATOR_MODEL_IDENTIFIER rather
        // than hw.machine, which would report the host Mac's architecture.
        XCTAssertNotEqual(model, "arm64", "device_model reports the host architecture")
        XCTAssertNotEqual(model, "x86_64")
    }

    func testScreenGeometryIsPositive() {
        let profile = DeviceProfile.current()
        XCTAssertGreaterThan(Int(profile["screen_width"] ?? "0") ?? 0, 0)
        XCTAssertGreaterThan(Int(profile["screen_height"] ?? "0") ?? 0, 0)
        XCTAssertGreaterThan(Double(profile["pixel_ratio"] ?? "0") ?? 0, 0)
        XCTAssertGreaterThan(Int(profile["screen_dpi"] ?? "0") ?? 0, 0)
    }

    func testBooleanSignalsAreStringifiedConsistently() {
        let profile = DeviceProfile.current()
        for key in ["is_emulator", "is_hardware_id_real"] {
            XCTAssertTrue(
                ["true", "false"].contains(profile[key] ?? ""),
                "\(key) is not a stringified bool: \(profile[key] ?? "nil")")
        }
    }

    func testEnvironmentIsAKnownValue() {
        XCTAssertTrue(["FULL_APP", "APP_CLIP"].contains(DeviceProfile.current()["environment"] ?? ""))
    }

    func testRunningOnTheSimulatorIsReported() {
        #if targetEnvironment(simulator)
            XCTAssertEqual(DeviceProfile.current()["is_emulator"], "true")
        #endif
    }

    // MARK: - Caching

    func testRepeatedReadsReturnTheSameProfile() {
        let first = DeviceProfile.current()
        let second = DeviceProfile.current()
        XCTAssertEqual(first, second)
    }

    /// The profile is cached in `UserDefaults`, not the keychain: keychain
    /// items survive app deletion, so a cached profile stored there would be
    /// resurrected onto a fresh install and describe the previous one.
    func testProfileIsPersistedInUserDefaults() {
        _ = DeviceProfile.current()

        XCTAssertNotNil(UserDefaults.standard.dictionary(forKey: "dl_static_profile"))
        XCTAssertNotNil(UserDefaults.standard.string(forKey: "dl_static_profile_stamp"))
    }

    /// A cold cache reads the stored profile back rather than re-collecting, so
    /// the values have to survive the round trip unchanged.
    func testStoredProfileIsReadBackIntact() {
        let collected = DeviceProfile.current()
        DeviceProfile.invalidate()
        // `invalidate` clears storage too, so restore it to model a fresh
        // process reading what a previous one wrote.
        UserDefaults.standard.set(collected, forKey: "dl_static_profile")
        UserDefaults.standard.set(
            collected["static_profile_version"], forKey: "dl_static_profile_stamp")

        XCTAssertEqual(DeviceProfile.current(), collected)
    }

    /// A stamp mismatch — a new SDK version, a new app build, a restore onto a
    /// different device — forces a re-collect rather than serving stale values.
    func testAStaleStampForcesRecollection() {
        let collected = DeviceProfile.current()
        DeviceProfile.invalidate()
        UserDefaults.standard.set(
            ["platform": "android", "sdk_version": "0.0.0"], forKey: "dl_static_profile")
        UserDefaults.standard.set("a-stamp-from-another-build", forKey: "dl_static_profile_stamp")

        let recollected = DeviceProfile.current()
        XCTAssertEqual(recollected["platform"], "ios")
        XCTAssertEqual(recollected["sdk_version"], collected["sdk_version"])
    }

    func testInvalidateClearsBothCacheAndStorage() {
        _ = DeviceProfile.current()
        DeviceProfile.invalidate()

        XCTAssertNil(UserDefaults.standard.dictionary(forKey: "dl_static_profile"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "dl_static_profile_stamp"))
    }

    // MARK: - The stamp

    /// Stable across collections within one build — otherwise every launch
    /// re-collects and the cache is pointless.
    func testStampIsStableAcrossCollections() {
        let first = DeviceProfile.current()["static_profile_version"]
        DeviceProfile.invalidate()
        let second = DeviceProfile.current()["static_profile_version"]
        XCTAssertEqual(first, second)
    }

    func testStampIsAShortHexDigest() {
        let stamp = DeviceProfile.current()["static_profile_version"] ?? ""
        XCTAssertEqual(stamp.count, 16, "stamp is not a 64-bit hex digest: \(stamp)")
        XCTAssertTrue(stamp.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Latches

    /// First-seen values, latched: `installed_at` is when the app's container
    /// was created, `first_open_at` is the first time our code ran — which is
    /// what an install cohort actually means.
    func testFirstSeenValuesAreLatchedOnFirstCollection() {
        let first = DeviceProfile.current()
        let firstOpen = first["first_open_at"]
        XCTAssertNotNil(firstOpen)

        DeviceProfile.invalidate()
        XCTAssertEqual(
            DeviceProfile.current()["first_open_at"], firstOpen,
            "first_open_at moved on a re-collect")
    }

    func testInstallInstanceIdIsStableAcrossRecollection() {
        let first = DeviceProfile.current()["install_instance_id"]
        DeviceProfile.invalidate()
        XCTAssertEqual(DeviceProfile.current()["install_instance_id"], first)
    }

    /// `EnrichmentSender` latches `"<source>_enriched"` forever. For sources
    /// with no click identity — `app_start` above all — that meant an app
    /// upgrade never re-reported the new `app_version`, because the latch was
    /// set on first launch of the first version and never cleared. A collect is
    /// exactly the moment that becomes wrong.
    func testCollectionClearsTheIdentitylessEnrichmentLatches() {
        UserDefaults.standard.set(true, forKey: "app_start_enriched")

        DeviceProfile.invalidate()
        _ = DeviceProfile.current()

        XCTAssertFalse(UserDefaults.standard.bool(forKey: "app_start_enriched"))
    }

    /// Only the identityless ones. A latch naming a specific click is matched
    /// on `hasSuffix`, which it fails — and rightly: it dedupes one link, and
    /// clearing it would re-send that link's enrichment on every app upgrade.
    func testCollectionKeepsLatchesThatNameAnIdentity() {
        UserDefaults.standard.set(true, forKey: "deep_link_enriched_click_id=c1")

        DeviceProfile.invalidate()
        _ = DeviceProfile.current()

        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: "deep_link_enriched_click_id=c1"),
            "a per-click dedupe latch was cleared by a profile re-collect")
    }

    /// Reading a cached profile is not a collection, so it must not clear the
    /// latches — that would make every read re-send every source.
    func testReadingACachedProfileLeavesLatchesAlone() {
        _ = DeviceProfile.current()
        UserDefaults.standard.set(true, forKey: "app_start_enriched")

        _ = DeviceProfile.current()

        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: "app_start_enriched"),
            "a cached read cleared the dedupe latches")
    }

    // MARK: - Concurrency

    /// Single-flight under a plain lock: collection is synchronous, so there is
    /// no completion plumbing. Concurrent readers must still agree.
    func testConcurrentReadsAgreeOnOneProfile() {
        let results = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            let profile = DeviceProfile.current()
            lock.lock()
            results.add(profile)
            lock.unlock()
        }

        let distinct = Set(results.compactMap { ($0 as? [String: String])?["install_instance_id"] })
        XCTAssertEqual(distinct.count, 1)
    }
}
