import XCTest

@testable import Deeplinkly

/// The privacy manifests, checked against the catalogue that decides what the
/// SDK may actually send.
///
/// These exist because of how catalogue 9 landed: `setUserData()` shipped in all
/// four SDKs, storing and transmitting email, phone, name, date of birth,
/// gender and postal address, and the bundled manifest was not touched. Nothing
/// noticed, because a plist is not compiled and no test read it. The gap was
/// found by hand three weeks later.
///
/// So the useful assertion is not "the manifest parses". It is that every
/// user-scope signal the catalogue defines has somewhere to be declared — which
/// is what fails on the commit that adds a catalogue-10 field, rather than at an
/// App Store review two months later.
final class PrivacyManifestTests: XCTestCase {

    /// Which Apple data type covers each user-scope signal.
    ///
    /// Hand-written, because Apple's list is Apple's and cannot be derived from
    /// ours. The test below is what keeps it honest: a new user-scope signal
    /// with no entry here fails, and the person adding it has to decide which
    /// type covers it rather than discovering that nobody did.
    ///
    /// Date of birth and gender fall to the catch-all: Apple's contact-info
    /// types stop at name, email, phone and address, and `SensitiveInfo`
    /// enumerates a closed list that includes neither.
    private static let dataTypeForSignal: [String: String] = [
        "custom_user_id": "NSPrivacyCollectedDataTypeUserID",
        "user_email": "NSPrivacyCollectedDataTypeEmailAddress",
        "user_phone": "NSPrivacyCollectedDataTypePhoneNumber",
        "user_first_name": "NSPrivacyCollectedDataTypeName",
        "user_last_name": "NSPrivacyCollectedDataTypeName",
        "user_date_of_birth": "NSPrivacyCollectedDataTypeOtherDataTypes",
        "user_gender": "NSPrivacyCollectedDataTypeOtherDataTypes",
        "user_street": "NSPrivacyCollectedDataTypePhysicalAddress",
        "user_city": "NSPrivacyCollectedDataTypePhysicalAddress",
        "user_state": "NSPrivacyCollectedDataTypePhysicalAddress",
        "user_zip": "NSPrivacyCollectedDataTypePhysicalAddress",
        "user_country": "NSPrivacyCollectedDataTypePhysicalAddress",
        // The open field carries account-level ids from the host app's own
        // stack (Mixpanel, Amplitude, CleverTap), which is what Apple means
        // by User ID. Same type as custom_user_id, so the bundled manifest
        // and the forwarding template already declare it.
        "user_custom_data": "NSPrivacyCollectedDataTypeUserID",
    ]

    // MARK: - Loading

    private func manifest(_ data: Data) throws -> [String: Any] {
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    /// The manifest Xcode aggregates into every host app's privacy report.
    private func bundledManifest() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "the bundled privacy manifest is missing from the resource bundle")
        return try manifest(Data(contentsOf: url))
    }

    /// A template, read from the source tree rather than the bundle.
    ///
    /// Not being bundled is the entire point of these two files — a tracking
    /// declaration inside the SDK's own manifest would be made on behalf of
    /// every host app — so `Bundle.module` cannot reach them and `#filePath` is
    /// how the test finds what the release ships.
    private func template(_ directory: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DeeplinklyTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = root
            .appendingPathComponent("Sources/Deeplinkly/Resources")
            .appendingPathComponent(directory)
            .appendingPathComponent("PrivacyInfo.xcprivacy")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "\(directory)/PrivacyInfo.xcprivacy is missing. It ships in the "
                + "release or host apps have nothing to merge.")
        return try manifest(Data(contentsOf: url))
    }

    private func collectedTypes(_ manifest: [String: Any]) -> [[String: Any]] {
        (manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []
    }

    private func declaredTypeNames(_ manifest: [String: Any]) -> Set<String> {
        Set(collectedTypes(manifest).compactMap { $0["NSPrivacyCollectedDataType"] as? String })
    }

    // MARK: - The catalogue gate

    func testEveryUserScopeSignalHasADeclaredDataType() throws {
        let unmapped = SignalCatalogue.keys(for: .user)
            .filter { Self.dataTypeForSignal[$0] == nil }
            .sorted()
        XCTAssertEqual(
            unmapped, [],
            "user-scope signals with no Apple data type mapped. Decide which "
                + "NSPrivacyCollectedDataType covers each, add it to "
                + "dataTypeForSignal, and declare it in both the bundled "
                + "manifest and the ConversionForwarding template.")
    }

    func testBundledManifestDeclaresEveryUserScopeDataType() throws {
        let declared = declaredTypeNames(try bundledManifest())
        let required = Set(
            SignalCatalogue.keys(for: .user).compactMap { Self.dataTypeForSignal[$0] })
        XCTAssertEqual(
            required.subtracting(declared).sorted(), [],
            "the SDK can transmit these and the bundled manifest does not "
                + "declare them")
    }

    // MARK: - The bundled manifest makes no tracking claim

    func testBundledManifestDoesNotDeclareTracking() throws {
        let bundled = try bundledManifest()
        XCTAssertEqual(
            bundled["NSPrivacyTracking"] as? Bool, false,
            "a tracking declaration here is made on behalf of every host app, "
                + "including the ones that never forward a conversion")

        for entry in collectedTypes(bundled) {
            let name = entry["NSPrivacyCollectedDataType"] as? String ?? "?"
            XCTAssertEqual(
                entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false,
                "\(name) is marked as tracking in the bundled manifest")
            let purposes = entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
            XCTAssertFalse(
                purposes.contains("NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising"),
                "\(name) claims third-party advertising in the bundled manifest; "
                    + "that belongs in the ConversionForwarding template")
        }
    }

    // MARK: - The templates do

    func testConversionForwardingTemplateDeclaresTrackingOnEveryType() throws {
        let forwarding = try template("ConversionForwarding")
        XCTAssertEqual(forwarding["NSPrivacyTracking"] as? Bool, true)
        XCTAssertFalse(
            (forwarding["NSPrivacyTrackingDomains"] as? [String] ?? []).isEmpty,
            "a tracking declaration with no tracking domains understates where "
                + "the data goes")

        let entries = collectedTypes(forwarding)
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let name = entry["NSPrivacyCollectedDataType"] as? String ?? "?"
            XCTAssertEqual(
                entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, true,
                "\(name) is in the forwarding template without being marked as "
                    + "tracking, which is the one thing the template is for")
            let purposes = entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
            XCTAssertTrue(
                purposes.contains("NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising"),
                "\(name) does not claim third-party advertising")
        }
    }

    func testConversionForwardingTemplateCoversTheMatchKeys() throws {
        let declared = declaredTypeNames(try template("ConversionForwarding"))
        let required = Set(
            SignalCatalogue.keys(for: .user).compactMap { Self.dataTypeForSignal[$0] })
        XCTAssertEqual(
            required.subtracting(declared).sorted(), [],
            "these are forwarded as match keys and the template does not "
                + "declare them")
    }

    func testIDFATemplateStillDeclaresTracking() throws {
        // The precedent this file follows. If it ever stops being true, the
        // argument for keeping either template out of the bundle is gone.
        let idfa = try template("IDFA")
        XCTAssertEqual(idfa["NSPrivacyTracking"] as? Bool, true)
    }
}
