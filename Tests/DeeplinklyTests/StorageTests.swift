import XCTest

@testable import Deeplinkly

/// `Keychain`, `DeviceIdManager`, `Prefs` and `TrackingPreferences` — the small
/// persistence units. Small, but the install id is the thing every attribution
/// hangs off, so losing or duplicating it splits one user in two.
final class StorageTests: XCTestCase {

    private let scratchKey = "deeplinkly_test_scratch"

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        Keychain.delete(scratchKey)
    }

    override func tearDown() {
        Keychain.delete(scratchKey)
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    // MARK: - Keychain

    func testKeychainRoundTrips() {
        XCTAssertTrue(Keychain.set("value-1", for: scratchKey))
        XCTAssertEqual(Keychain.get(scratchKey), "value-1")
    }

    func testKeychainReadsNilForAnAbsentKey() {
        XCTAssertNil(Keychain.get("deeplinkly_test_absent"))
    }

    /// `set` deletes before adding, so writing twice updates rather than
    /// failing with a duplicate-item error.
    func testKeychainOverwrites() {
        Keychain.set("first", for: scratchKey)
        XCTAssertTrue(Keychain.set("second", for: scratchKey))
        XCTAssertEqual(Keychain.get(scratchKey), "second")
    }

    func testKeychainDeletes() {
        Keychain.set("value-1", for: scratchKey)
        XCTAssertTrue(Keychain.delete(scratchKey))
        XCTAssertNil(Keychain.get(scratchKey))
    }

    func testDeletingAnAbsentKeyReportsFalse() {
        XCTAssertFalse(Keychain.delete("deeplinkly_test_absent"))
    }

    func testKeychainHandlesUnicodeAndEmptyValues() {
        Keychain.set("", for: scratchKey)
        XCTAssertEqual(Keychain.get(scratchKey), "")

        Keychain.set("café — 🔗", for: scratchKey)
        XCTAssertEqual(Keychain.get(scratchKey), "café — 🔗")
    }

    /// Items are scoped by service, so the account name alone is not the whole
    /// key and two keys cannot collide.
    func testKeychainKeysAreIndependent() {
        Keychain.set("a", for: scratchKey)
        Keychain.set("b", for: "\(scratchKey)_other")
        defer { Keychain.delete("\(scratchKey)_other") }

        XCTAssertEqual(Keychain.get(scratchKey), "a")
        XCTAssertEqual(Keychain.get("\(scratchKey)_other"), "b")
    }

    // MARK: - DeviceIdManager

    /// The install id must be stable: a fresh one on a second read would split
    /// one user's attribution across two identities.
    func testDeviceIdIsStableAcrossReads() {
        let first = DeviceIdManager.getOrCreate()
        XCTAssertEqual(DeviceIdManager.getOrCreate(), first)
        XCTAssertFalse(first.isEmpty)
        XCTAssertNotNil(UUID(uuidString: first), "device id is not a UUID: \(first)")
    }

    /// It lives in the keychain rather than `UserDefaults` precisely so that
    /// clearing defaults does not mint a new identity.
    func testDeviceIdSurvivesAUserDefaultsWipe() {
        let first = DeviceIdManager.getOrCreate()
        DeeplinklyTestSupport.reset()
        XCTAssertEqual(DeviceIdManager.getOrCreate(), first)
    }

    func testConcurrentDeviceIdReadsAgree() {
        _ = DeviceIdManager.getOrCreate()
        let ids = NSMutableSet()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            let id = DeviceIdManager.getOrCreate()
            lock.lock()
            ids.add(id)
            lock.unlock()
        }
        XCTAssertEqual(ids.count, 1)
    }

    // MARK: - Prefs

    func testPrefsRoundTripsStringsAndBools() {
        Prefs.set("value", for: scratchKey)
        XCTAssertEqual(Prefs.string(for: scratchKey), "value")

        Prefs.set(true, for: scratchKey)
        XCTAssertTrue(Prefs.bool(for: scratchKey))

        UserDefaults.standard.removeObject(forKey: scratchKey)
    }

    /// The default for an unset flag is false — every latch in the SDK relies
    /// on "absent means not yet done".
    func testAnUnsetFlagReadsFalse() {
        XCTAssertFalse(Prefs.bool(for: "deeplinkly_test_never_written"))
        XCTAssertNil(Prefs.string(for: "deeplinkly_test_never_written"))
    }

    func testCustomUserIdRoundTrips() {
        XCTAssertNil(Prefs.customUserId())
        Prefs.setCustomUserId("user-1")
        XCTAssertEqual(Prefs.customUserId(), "user-1")
    }

    /// Clearing the id has to actually clear it — a logout that left the
    /// previous user's id attached would misattribute everything after it.
    func testCustomUserIdCanBeCleared() {
        Prefs.setCustomUserId("user-1")
        Prefs.setCustomUserId(nil)
        XCTAssertNil(Prefs.customUserId())
    }

    /// Persisted state on live installs; the key is frozen.
    func testCustomUserIdKeyIsStable() {
        Prefs.setCustomUserId("user-1")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "custom_user_id"), "user-1")
    }

    // MARK: - TrackingPreferences

    func testTrackingIsEnabledByDefault() {
        XCTAssertFalse(TrackingPreferences.isTrackingDisabled())
    }

    func testTrackingSwitchRoundTrips() {
        TrackingPreferences.setTrackingDisabled(true)
        XCTAssertTrue(TrackingPreferences.isTrackingDisabled())

        TrackingPreferences.setTrackingDisabled(false)
        XCTAssertFalse(TrackingPreferences.isTrackingDisabled())
    }

    func testTrackingKeyIsStable() {
        TrackingPreferences.setTrackingDisabled(true)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "tracking_disabled"))
    }
}
