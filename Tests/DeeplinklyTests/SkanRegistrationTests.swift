import XCTest

@testable import Deeplinkly

/// Registering with SKAdNetwork is what makes a postback exist at all.
///
/// Apple sends nothing unless the advertised app registers on launch, so the
/// `NSAdvertisingAttributionReportEndpoint` key a host adds to its Info.plist
/// is only an address — it does not cause anything to be sent to it. That makes
/// this the difference between iOS SKAN working and iOS SKAN being silently
/// dead for the life of a build, which is why it is tested rather than assumed.
///
/// What these can see is the *decision*: whether the SDK chose to register.
/// StoreKit's own behaviour cannot be exercised here — a real postback needs a
/// real device, a real ad impression and Apple's 24-hour timer — so the call
/// itself is behind `registrarForTesting`.
final class SkanRegistrationTests: XCTestCase {
    private var registrations = 0

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        registrations = 0
        SkanRegistration.registrarForTesting = { [weak self] in
            self?.registrations += 1
        }
    }

    override func tearDown() {
        SkanRegistration.registrarForTesting = nil
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    func testRegistersOnce() {
        SkanRegistration.register()

        XCTAssertEqual(registrations, 1)
    }

    /// The opt-out is the one gate. Registering causes postbacks that would not
    /// otherwise be generated, so a user who turned tracking off should not
    /// produce them.
    func testDoesNotRegisterWhileTrackingIsDisabled() {
        TrackingPreferences.setTrackingDisabled(true)

        SkanRegistration.register()

        XCTAssertEqual(registrations, 0)
    }

    /// Re-enabling has to start working again without an app reinstall.
    func testRegistersAgainAfterTrackingIsReEnabled() {
        TrackingPreferences.setTrackingDisabled(true)
        SkanRegistration.register()
        TrackingPreferences.setTrackingDisabled(false)

        SkanRegistration.register()

        XCTAssertEqual(registrations, 1)
    }

    /// The attribution level deliberately does *not* gate this.
    ///
    /// The levels govern what the SDK observes about a device. A SKAdNetwork
    /// postback observes nothing — Apple aggregates and thresholds it before
    /// anyone sees it, and it carries no device identifier — so gating it at
    /// `minimal` or `reduced` would cost installs and protect no one.
    func testTheAttributionLevelDoesNotGateRegistration() {
        for level in [AttributionLevel.full, .reduced, .minimal] {
            registrations = 0
            AttributionLevel.set(level)

            SkanRegistration.register()

            XCTAssertEqual(registrations, 1, "level \(level.rawValue) suppressed registration")
        }
    }
}

/// Registration has to be wired into startup, not merely available.
///
/// Separate from the suite above because it exercises `Deeplinkly.initialize`,
/// which does a great deal more than register — the point here is only that the
/// call is on that path at all. A refactor that dropped the line would leave
/// every test above passing.
final class SkanRegistrationStartupTests: XCTestCase {
    private var registrations = 0

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        registrations = 0
        SkanRegistration.registrarForTesting = { [weak self] in
            self?.registrations += 1
        }
    }

    override func tearDown() {
        SkanRegistration.registrarForTesting = nil
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    func testInitializeRegisters() {
        Deeplinkly.initialize(apiKey: "test-key")

        XCTAssertEqual(registrations, 1, "initialize() no longer registers for SKAdNetwork")
    }

    /// An empty key means the SDK is misconfigured and returns early. Nothing
    /// should be reported to Apple on that path either.
    func testInitializeWithoutAnApiKeyDoesNotRegister() {
        Deeplinkly.initialize(apiKey: "")

        XCTAssertEqual(registrations, 0)
    }
}
