import XCTest

@testable import Deeplinkly

/// `user_custom_data`, the open field behind `Deeplinkly.setUserData`.
///
/// It exists so a thirteenth identifier — a Mixpanel distinct id, a CleverTap
/// id — does not need every host app to ship again. That is exactly why its
/// bounds are worth testing: an open field that is also unbounded is a
/// different problem from the one it was added to solve.
///
/// The Kotlin twin is `DeeplinklyUserDataCustomTest`; the two are meant to be
/// read side by side, and a case added to one belongs in the other.
final class DeeplinklyUserDataCustomTests: XCTestCase {

    func testEncodesCustomDataAsJSONObject() throws {
        let (encoded, rejection) = DeeplinklyUserData.encodeCustomData([
            "mixpanel_distinct_id": "abc123",
            "clevertap_id": "  xyz  ",
        ])
        XCTAssertNil(rejection)
        let data = try XCTUnwrap(encoded?.data(using: .utf8))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(json["mixpanel_distinct_id"], "abc123")
        // Trimmed, like every other field.
        XCTAssertEqual(json["clevertap_id"], "xyz")
    }

    func testAbsentCustomDataIsAbsentRatherThanEmpty() {
        // nil, an empty dictionary, and one of only blanks all mean "said
        // nothing about custom data", which merges as leave-alone. An empty
        // JSON object would instead overwrite what was stored with nothing.
        let inputs: [[String: String?]?] = [
            nil,
            [:],
            ["k": "   "],
            ["": "v"],
        ]
        for input in inputs {
            let (encoded, rejection) = DeeplinklyUserData.encodeCustomData(input)
            XCTAssertNil(rejection)
            XCTAssertNil(encoded)
        }
    }

    func testRejectsOverLongCustomKeyOrValue() {
        let longKey = String(
            repeating: "k", count: DeeplinklyUserData.maxCustomKeyLength + 1)
        XCTAssertNotNil(DeeplinklyUserData.encodeCustomData([longKey: "v"]).1)

        let longValue = String(
            repeating: "v", count: DeeplinklyUserData.maxCustomValueLength + 1)
        XCTAssertNotNil(DeeplinklyUserData.encodeCustomData(["k": longValue]).1)
    }

    func testRejectsMoreEntriesThanTheCap() {
        var tooMany: [String: String?] = [:]
        for i in 0...DeeplinklyUserData.maxCustomEntries {
            tooMany["key\(i)"] = "value\(i)"
        }
        let (encoded, rejection) = DeeplinklyUserData.encodeCustomData(tooMany)
        XCTAssertNil(encoded)
        XCTAssertNotNil(rejection)
    }

    func testWorstLegalBlobStillFitsTheCatalogueLength() {
        // The largest thing a caller can legally build, against the max_len the
        // catalogue gives user_custom_data. If this ever fails, the field is
        // accepted here and then rejected in normalize(), which is a confusing
        // way to lose data — the caps and the max_len have to agree.
        let keyBody = String(
            repeating: "k", count: DeeplinklyUserData.maxCustomKeyLength - 2)
        var worst: [String: String?] = [:]
        for i in 10..<(10 + DeeplinklyUserData.maxCustomEntries) {
            worst["\(keyBody)\(i)"] = String(
                repeating: "v", count: DeeplinklyUserData.maxCustomValueLength)
        }
        let (encoded, rejection) = DeeplinklyUserData.encodeCustomData(worst)
        XCTAssertNil(rejection)
        XCTAssertNotNil(encoded)

        let (normalized, normalizeRejection) = DeeplinklyUserData.normalize(
            DeeplinklyUserData.keyCustomData, encoded)
        XCTAssertNil(normalizeRejection)
        XCTAssertNotNil(normalized)
    }

    func testEncodingIsStableForTheSameInput() {
        // Dictionary iteration order is not stable in Swift, so without
        // .sortedKeys the same input would encode to different strings between
        // calls and look like a changed value to the merge on the far side.
        let input: [String: String?] = ["b": "2", "a": "1", "c": "3"]
        let first = DeeplinklyUserData.encodeCustomData(input).0
        for _ in 0..<20 {
            XCTAssertEqual(DeeplinklyUserData.encodeCustomData(input).0, first)
        }
    }

    func testCustomDataKeyIsOneTheStoreKeeps() {
        // The key has to be one UserDataStore will hold, or the blob is
        // silently dropped on the way to the wire.
        XCTAssertTrue(
            DeeplinklyUserData.keys.contains(DeeplinklyUserData.keyCustomData))
    }
}
