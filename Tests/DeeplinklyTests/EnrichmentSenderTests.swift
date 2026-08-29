import XCTest

@testable import Deeplinkly

/// The one place an enrichment payload is assembled, and the decisions it makes
/// about whether to send at all.
///
/// All of it was unobservable before the session became injectable: the dedupe
/// latch is written inside a network completion, so nothing distinguished
/// "skipped" from "attempted and failed".
final class EnrichmentSenderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeeplinklyTestSupport.reset()
        StubURLProtocol.install()
        StubURLProtocol.stub(DomainConfig.enrich, .ok())
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        DeeplinklyTestSupport.reset()
        super.tearDown()
    }

    private func send(
        _ attribution: [String: String?] = [:], source: String = "deep_link", force: Bool = false
    ) {
        EnrichmentSender.sendOnce(
            attributionData: attribution, source: source, apiKey: "test-key", force: force)
    }

    private var enrichments: [StubURLProtocol.Recorded] {
        StubURLProtocol.requests(to: DomainConfig.enrich)
    }

    private func waitForEnrichment(count: Int = 1) -> [StubURLProtocol.Recorded] {
        StubURLProtocol.waitForRequest(to: DomainConfig.enrich, count: count)
    }

    // MARK: - Payload assembly

    /// Callers pass only the link identity; the device description is added
    /// here, at send time, so a payload replayed from storage days later still
    /// describes the device as it is now.
    func testThePayloadCombinesDeviceProfileDynamicSignalsAndAttribution() {
        send(["click_id": "c1", "utm_source": "news"])

        let body = waitForEnrichment().first?.body
        XCTAssertEqual(body?["click_id"] as? String, "c1")
        XCTAssertEqual(body?["utm_source"] as? String, "news")
        XCTAssertNotNil(body?["platform"], "no static profile in the payload")
        XCTAssertNotNil(body?["att_status"], "no dynamic sample in the payload")
    }

    /// `sendOnce`'s doc comment says "device signals passed here are
    /// overwritten". They are not: `attributionData` is merged **last**, so a
    /// caller's value wins over the collected one.
    ///
    /// Pinned as it actually behaves rather than as documented, because no
    /// caller exercises the difference — all four pass link identity only
    /// (`DeepLinkHandler` passes source/click_id/ios_reported_at,
    /// `StartupEnrichment` passes the stored attribution, `AppOpenReporter` and
    /// `UserIdManager` pass nothing). The comment is aspirational; the merge
    /// order is what runs. Flagged rather than "fixed": reordering would be a
    /// behaviour change no caller has asked for.
    func testCallerSuppliedValuesWinOverCollectedOnes() {
        send(["click_id": "c1", "platform": "android"])

        XCTAssertEqual(
            waitForEnrichment().first?.body?["platform"] as? String, "android",
            "the merge order changed; EnrichmentSender's doc comment now describes it correctly")
    }

    /// What the comment is really protecting: nothing device-shaped is carried
    /// in from a queue, because the device half is collected fresh here at send
    /// time rather than passed in.
    func testTheDeviceHalfIsCollectedFreshAtSendTime() {
        send(["click_id": "c1"])

        let body = waitForEnrichment().first?.body
        XCTAssertEqual(body?["platform"] as? String, "ios")
        XCTAssertEqual(body?["sdk_version"] as? String, SdkInfo.version)
        XCTAssertNotNil(body?["last_opened_at"], "no freshly-collected dynamic signal")
    }

    /// Reported so the service can tell a thin payload from a missing one.
    func testThePayloadDescribesItself() {
        AttributionLevel.set(.minimal)
        send(["click_id": "c1"])

        let body = waitForEnrichment().first?.body
        XCTAssertEqual(body?["attribution_level"] as? String, "minimal")
        XCTAssertNotNil(body?["collected_at"])
    }

    func testTheCustomUserIdRidesAlong() {
        Prefs.setCustomUserId("user-1")
        send(["click_id": "c1"])

        XCTAssertEqual(waitForEnrichment().first?.body?["custom_user_id"] as? String, "user-1")
    }

    // MARK: - Attribution level

    func testThePayloadIsFilteredToTheLevelInForce() {
        AttributionLevel.set(.reduced)
        send(["click_id": "c1"])

        let body = waitForEnrichment().first?.body
        XCTAssertNotNil(body?["click_id"])
        XCTAssertNotNil(body?["locale"], "a reduced-tier signal was dropped")
        XCTAssertNil(body?["screen_width"], "a full-tier signal survived level reduced")
    }

    func testNothingIsSentAtLevelNone() {
        AttributionLevel.set(.none)
        send(["click_id": "c1"])

        StubURLProtocol.assertNoRequest(to: DomainConfig.enrich)
    }

    func testNothingIsSentWhileTrackingIsDisabled() {
        TrackingPreferences.setTrackingDisabled(true)
        send(["click_id": "c1"])

        StubURLProtocol.assertNoRequest(to: DomainConfig.enrich)
    }

    // MARK: - The attribution gate

    /// "Only send if we have attribution hints." An install with nothing
    /// pointing at it is not reported through this path.
    func testAPayloadWithNoAttributionIsNotSent() {
        send([:])

        StubURLProtocol.assertNoRequest(to: DomainConfig.enrich)
    }

    /// `code` counts too — Android counts it, and a code-only deferred link was
    /// silently dropped before it did here.
    func testACodeAloneSatisfiesTheGate() {
        send(["code": "abc"])

        waitForEnrichment()
    }

    func testAnyAdClickIdSatisfiesTheGate() {
        send(["gclid": "g1"])

        waitForEnrichment()
    }

    /// `force` is how `StartupEnrichment` reports an install that never
    /// resolved a link — still a real install.
    func testForceSendsWithoutAttribution() {
        send([:], source: "app_start", force: true)

        waitForEnrichment()
    }

    /// Lifecycle sources are exempt: an app open is a moment, not a link.
    func testLifecycleSourcesBypassTheGate() {
        send([:], source: "app_open")

        waitForEnrichment()
    }

    // MARK: - The dedupe latch

    /// Two calls that would report the same thing collapse to one.
    func testASecondIdenticalSendIsSuppressed() {
        send(["click_id": "c1"])
        waitForEnrichment()

        send(["click_id": "c1"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(enrichments.count, 1, "the same enrichment was sent twice")
    }

    /// The latch used to be keyed on source alone and never cleared, which made
    /// every source once-per-install *forever*: the second and every later deep
    /// link never enriched. Keying on what is being reported lets a genuinely
    /// new link through.
    func testADifferentLinkIsStillSent() {
        send(["click_id": "c1"])
        waitForEnrichment()

        send(["click_id": "c2"])
        waitForEnrichment(count: 2)
    }

    /// Same reason `setUserId` only ever linked the first login on a device.
    func testADifferentUserIdIsStillSent() {
        Prefs.setCustomUserId("user-1")
        send([:], source: "custom_user_id", force: true)
        waitForEnrichment()

        Prefs.setCustomUserId("user-2")
        send([:], source: "custom_user_id", force: true)
        waitForEnrichment(count: 2)
    }

    /// Lifecycle sources are exempt from the latch too — they are rate-limited
    /// by their own caller, and a latch here would drop a fresh dynamic sample
    /// rather than merely collapsing a duplicate.
    func testLifecycleSourcesAreNotLatched() {
        send([:], source: "app_open")
        waitForEnrichment()

        send([:], source: "app_open")
        waitForEnrichment(count: 2)
    }

    /// "Latch only once the payload is actually delivered. Setting it up front
    /// marked a permanently failing enrichment as sent."
    func testAFailedSendIsNotLatchedAndIsRetriedLater() {
        StubURLProtocol.stub(DomainConfig.enrich, .offline)
        send(["click_id": "c1"])
        waitForEnrichment()

        StubURLProtocol.stub(DomainConfig.enrich, .ok())
        send(["click_id": "c1"])
        waitForEnrichment(count: 2)
    }

    /// A terminal rejection counts as delivered — it will never succeed, so
    /// re-sending it every launch achieves nothing.
    func testATerminallyRejectedSendIsLatched() {
        StubURLProtocol.stub(DomainConfig.enrich, .terminal(403))
        send(["click_id": "c1"])
        waitForEnrichment()

        StubURLProtocol.stub(DomainConfig.enrich, .ok())
        send(["click_id": "c1"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(enrichments.count, 1, "a rejected enrichment was retried on every call")
    }

    /// The latch key is not `hashValue`: Swift seeds String hashing per
    /// process, so the key would differ on every launch and dedupe nothing.
    /// A latch written by one "launch" must still suppress in the next.
    func testTheLatchSurvivesAcrossProcesses() {
        send(["click_id": "c1"])
        waitForEnrichment()

        let latches = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.contains("_enriched") }
        XCTAssertFalse(latches.isEmpty, "no latch was written")
        for key in latches {
            XCTAssertFalse(
                key.contains("-"), "latch key looks hash-derived and will not survive a relaunch")
        }
    }

    // MARK: - User data

    /// The whole point of the `user` scope: what the app told us about the
    /// person rides along on the enrichment, so a conversion forwarded later can
    /// be matched at Meta or Google without the event itself having to carry it.
    func testUserDataRidesAlongOnThePayload() {
        UserDataStore.merge([
            DeeplinklyUserData.keyEmail: "ada@example.com",
            DeeplinklyUserData.keyCountry: "GB",
        ])

        send(["click_id": "c1"])

        let body = waitForEnrichment().first?.body
        XCTAssertEqual(body?[DeeplinklyUserData.keyEmail] as? String, "ada@example.com")
        XCTAssertEqual(body?[DeeplinklyUserData.keyCountry] as? String, "GB")
    }

    /// Empty is a value here, not an absence. `UserDataStore.clear` tombstones
    /// each set field to "" and the service reads that as "erase this column"; a
    /// filter that dropped empties on the way out would turn a deletion into a
    /// no-op without anyone noticing.
    func testATombstonedFieldIsSentAsAnEmptyValue() {
        UserDataStore.merge([DeeplinklyUserData.keyEmail: "ada@example.com"])
        UserDataStore.clear()

        send(["click_id": "c1"])

        let body = waitForEnrichment().first?.body
        XCTAssertEqual(body?[DeeplinklyUserData.keyEmail] as? String, "")
    }

    /// The latch is keyed on what is being reported. For this source that is the
    /// user data itself, so adding an address to an email already sent — the
    /// ordinary second call — must not collapse into the first.
    func testASecondUserDataReportWithDifferentFieldsIsNotDeduped() {
        UserDataStore.merge([DeeplinklyUserData.keyEmail: "ada@example.com"])
        send(source: EnrichmentSender.userDataSource, force: true)
        _ = waitForEnrichment(count: 1)

        UserDataStore.merge([DeeplinklyUserData.keyCity: "London"])
        send(source: EnrichmentSender.userDataSource, force: true)

        let bodies = waitForEnrichment(count: 2)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[1].body?[DeeplinklyUserData.keyCity] as? String, "London")
    }

    /// A dedupe key becomes the name of a `UserDefaults` entry, and an email
    /// address written into one would sit somewhere neither `clearUserData` nor
    /// the tombstone can reach — and outside `PrivacyData`'s inventory besides.
    func testTheDedupeKeyDoesNotContainTheUserDataItself() {
        let key = EnrichmentSender.dedupeKey(
            for: [DeeplinklyUserData.keyEmail: "ada@example.com"],
            source: EnrichmentSender.userDataSource)
        XCTAssertFalse(key.contains("ada@example.com"))
    }

    /// Stable across launches, and identical to the Kotlin implementation —
    /// which is the property `hashValue` does not have.
    func testTheDigestIsStableForAGivenInput() {
        XCTAssertEqual(
            EnrichmentSender.stableDigest("user_email=ada@example.com"),
            EnrichmentSender.stableDigest("user_email=ada@example.com"))
        XCTAssertNotEqual(
            EnrichmentSender.stableDigest("user_email=ada@example.com"),
            EnrichmentSender.stableDigest("user_email=grace@example.com"))
    }

    /// Other sources are unaffected: every enrichment now carries user data, and
    /// folding it into their keys too would re-send a deep-link report every
    /// time an unrelated field changed.
    func testUserDataDoesNotChangeTheDedupeKeyOfOtherSources() {
        let without = EnrichmentSender.dedupeKey(for: ["click_id": "c1"], source: "deep_link")
        let with = EnrichmentSender.dedupeKey(
            for: ["click_id": "c1", DeeplinklyUserData.keyEmail: "ada@example.com"],
            source: "deep_link")
        XCTAssertEqual(without, with)
    }

    // MARK: - Consent

    /// Consent has to reach the service on the ordinary enrichment path: it is
    /// what the forwarder reads when it decides whether a conversion may be
    /// uploaded at all.
    func testConsentRidesAlongOnThePayload() {
        ConsentStore.merge(adUserData: .granted, adPersonalization: .denied, isEEA: true)

        send(["click_id": "c1"])

        let body = waitForEnrichment().first?.body
        XCTAssertEqual(body?[ConsentStore.keyAdUserData] as? String, "granted")
        XCTAssertEqual(body?[ConsentStore.keyAdPersonalization] as? String, "denied")
        XCTAssertEqual(body?[ConsentStore.keyIsEEA] as? String, "true")
    }

    /// The failure this guards against. A grant followed by a withdrawal
    /// reports twice under one source, and an identity-only key would collapse
    /// the withdrawal into the grant — losing precisely the update that must
    /// not be lost.
    func testAWithdrawalAfterAGrantIsNotDedupedAway() {
        ConsentStore.merge(adUserData: .granted, adPersonalization: .granted, isEEA: nil)
        send(source: EnrichmentSender.consentSource, force: true)
        _ = waitForEnrichment(count: 1)

        ConsentStore.merge(adUserData: .denied, adPersonalization: .denied, isEEA: nil)
        send(source: EnrichmentSender.consentSource, force: true)

        let all = waitForEnrichment(count: 2)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.last?.body?[ConsentStore.keyAdUserData] as? String, "denied")
    }

    /// Consent is `minimal` tier, so it survives every level that sends
    /// anything at all. A level that stripped it would leave the forwarder
    /// unable to tell a denial from an app that never asked.
    func testConsentSurvivesTheStrictestLevelThatStillSends() {
        AttributionLevel.set(.minimal)
        ConsentStore.merge(adUserData: .denied, adPersonalization: .denied, isEEA: true)

        send(["click_id": "c1"])

        let body = waitForEnrichment().first?.body
        XCTAssertEqual(body?[ConsentStore.keyAdUserData] as? String, "denied")
    }

    // MARK: - Push token

    func testThePushTokenRidesAlongOnThePayload() {
        PushTokenStore.set("tok-123", provider: .apns)

        send(["click_id": "c1"])

        let body = waitForEnrichment().first?.body
        XCTAssertEqual(body?["push_token"] as? String, "tok-123")
        XCTAssertEqual(body?["push_provider"] as? String, "apns")
    }

    /// Tokens rotate. A rotation reports under the same source and must not
    /// collapse into the first report, or the prober keeps pinging a token that
    /// no longer resolves and reads the failure as an uninstall.
    func testARotatedPushTokenIsNotDedupedAway() {
        PushTokenStore.set("tok-123", provider: .apns)
        send(source: EnrichmentSender.pushTokenSource, force: true)
        _ = waitForEnrichment(count: 1)

        PushTokenStore.set("tok-456", provider: .apns)
        send(source: EnrichmentSender.pushTokenSource, force: true)

        let all = waitForEnrichment(count: 2)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.last?.body?["push_token"] as? String, "tok-456")
    }

    /// `push_token` is FULL tier: a unique per-install identifier a server can
    /// address. An app at REDUCED does not report it and does not get uninstall
    /// measurement. That is the level working, and pinning it here means a
    /// future reclassification has to be deliberate.
    func testThePushTokenIsDroppedBelowFull() {
        AttributionLevel.set(.reduced)
        PushTokenStore.set("tok-123", provider: .apns)

        send(["click_id": "c1"])

        let body = waitForEnrichment().first?.body
        XCTAssertNil(body?["push_token"])
        XCTAssertNil(body?["push_provider"])
    }

    /// A dedupe key becomes the name of a UserDefaults entry, and a push token
    /// is an addressable identifier. It has to be digested, like the email
    /// address above, rather than written in plain.
    func testTheDedupeKeyDoesNotContainThePushTokenItself() {
        let key = EnrichmentSender.dedupeKey(
            for: ["push_token": "tok-123"], source: EnrichmentSender.pushTokenSource)
        XCTAssertFalse(key.contains("tok-123"))
    }
}
