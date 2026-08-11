import XCTest

@testable import Deeplinkly

/// Identity of the SDK build, and the two things that hang off it.
///
/// Android's twin is guarded by `SdkInfoTest` because the version there had
/// already drifted — shipping as 1.0.0 while reporting 1.9.0. On iOS the value
/// is hand-maintained (`CFBundleShortVersionString` in a static library
/// resolves to the *host app's* version, not ours), so it cannot be derived
/// from the build the way Kotlin's is. These are the guards that remain
/// possible: shape, and agreement with the podspec.
final class SdkInfoTests: XCTestCase {

    func testPlatformIsIos() {
        XCTAssertEqual(SdkInfo.platform, "ios")
    }

    func testVersionIsSemver() {
        XCTAssertNotNil(
            SdkInfo.version.range(of: "^\\d+\\.\\d+\\.\\d+$", options: .regularExpression),
            "SdkInfo.version is not a semver triple: \(SdkInfo.version)")
    }

    /// The version is folded into the static-profile stamp, so it has to be
    /// present or an SDK upgrade stops re-collecting the profile — which is
    /// what makes a signal added in a new release get collected on existing
    /// installs.
    func testVersionReachesTheStaticProfile() {
        DeviceProfile.invalidate()
        defer { DeviceProfile.invalidate() }
        XCTAssertEqual(DeviceProfile.current()["sdk_version"], SdkInfo.version)
    }

    /// Milliseconds since the SDK initialised in this process — the delta that
    /// orders events from a device whose wall clock is wrong. It must never run
    /// backwards, and must not be the raw `systemUptime`, which additionally
    /// revealed how long the device had been booted.
    func testElapsedSinceInitIsMonotonicAndSmall() {
        let first = SdkInfo.elapsedSinceInit()
        let second = SdkInfo.elapsedSinceInit()

        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
        XCTAssertLessThan(
            first, Int(ProcessInfo.processInfo.systemUptime * 1000),
            "elapsedSinceInit is reporting raw device uptime")
    }

    func testElapsedSinceInitAdvances() {
        let first = SdkInfo.elapsedSinceInit()
        let deadline = Date().addingTimeInterval(0.05)
        while Date() < deadline {}
        XCTAssertGreaterThan(SdkInfo.elapsedSinceInit(), first)
    }
}

/// The logger's only real behaviour: errors always print, everything else is
/// gated. An SDK that swallows its own failures silently is undebuggable.
final class LoggerTests: XCTestCase {

    override func tearDown() {
        Logger.setDebugMode(false)
        super.tearDown()
    }

    func testDebugIsOffByDefault() {
        Logger.setDebugMode(false)
        XCTAssertFalse(Logger.isDebugEnabled)
    }

    func testDebugModeTogglesBothWays() {
        Logger.setDebugMode(true)
        XCTAssertTrue(Logger.isDebugEnabled)

        Logger.setDebugMode(false)
        XCTAssertFalse(Logger.isDebugEnabled)
    }

    /// Logging while disabled is a no-op rather than a crash, on every level.
    func testEveryLevelIsSafeWhileDisabled() {
        Logger.setDebugMode(false)
        Logger.d("debug")
        Logger.w("warning")
        Logger.e("error")
        Logger.e("error", NetworkError.message("boom"))
    }

    func testEveryLevelIsSafeWhileEnabled() {
        Logger.setDebugMode(true)
        Logger.d("debug")
        Logger.w("warning")
        Logger.e("error", NetworkError.message("boom"))
    }

    /// Read from arbitrary queues while a host app may be flipping it.
    func testConcurrentAccessIsSafe() {
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            if index.isMultiple(of: 2) {
                Logger.setDebugMode(true)
            } else {
                _ = Logger.isDebugEnabled
                Logger.d("from \(index)")
            }
        }
    }
}

/// The endpoints. All five are production URLs on the frozen wire format.
final class DomainConfigTests: XCTestCase {

    func testEveryEndpointIsAnHttpsUrlUnderTheBase() {
        for endpoint in [
            DomainConfig.enrich, DomainConfig.logEvent, DomainConfig.sdkError,
            DomainConfig.resolveClick, DomainConfig.generateLink,
        ] {
            XCTAssertTrue(endpoint.hasPrefix("https://"), "\(endpoint) is not https")
            XCTAssertTrue(endpoint.hasPrefix(DomainConfig.base), "\(endpoint) is off-base")
            XCTAssertNotNil(URL(string: endpoint), "\(endpoint) does not parse")
        }
    }

    /// The paths are the wire contract with a production backend that one
    /// customer is live against on an older SDK.
    func testEndpointPathsAreFrozen() {
        XCTAssertEqual(DomainConfig.enrich, "\(DomainConfig.base)/api/v1/enrich")
        XCTAssertEqual(DomainConfig.logEvent, "\(DomainConfig.base)/api/v1/log-event")
        XCTAssertEqual(DomainConfig.sdkError, "\(DomainConfig.base)/api/v1/sdk-error")
        XCTAssertEqual(DomainConfig.resolveClick, "\(DomainConfig.base)/api/v1/resolve")
        XCTAssertEqual(DomainConfig.generateLink, "\(DomainConfig.base)/api/v1/generate-url")
    }

    func testEndpointsAreDistinct() {
        let endpoints = [
            DomainConfig.enrich, DomainConfig.logEvent, DomainConfig.sdkError,
            DomainConfig.resolveClick, DomainConfig.generateLink,
        ]
        XCTAssertEqual(Set(endpoints).count, endpoints.count)
    }
}
