// UserDataStore.swift
import Foundation

/// The person's own details, as the host app reported them.
///
/// One `UserDefaults` key holding one JSON object, rather than a key per field.
/// That is not only tidiness: `PrivacyData.persistedKeys` is a hand-maintained
/// inventory of everything the SDK writes, and eleven separately-named fields
/// would be eleven chances for whoever adds a twelfth to miss one — in the one
/// list where missing an entry means personal data survives a deletion.
///
/// ## Clearing
///
/// `clear()` does not simply delete the blob. A key that stops being sent is
/// indistinguishable, at the backend, from a key that was never sent — the
/// enrichment path skips absent values so a phone that failed to read its
/// carrier cannot blank the carrier we already know. So clearing writes a
/// tombstone instead: every key that currently holds a value is rewritten to
/// the empty string, which the backend reads as "erase this column".
///
/// The tombstone is kept rather than dropped after one send. Delivery is not
/// observable from here, and a clear silently lost because the device was
/// offline at that moment is the one failure this must not have. Empty keys are
/// idempotent on the far side, so re-sending them costs a few bytes and nothing
/// else.
enum UserDataStore {
    static let storageKey = "dl_user_data"

    /// Fields to merge into the enrichment payload. Empty when nothing is set.
    static func get() -> [String: String] {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
            let data = raw.data(using: .utf8)
        else { return [:] }

        guard let decoded = try? JSONSerialization.jsonObject(with: data),
            let object = decoded as? [String: Any]
        else {
            // A blob we cannot parse is a blob we cannot honour a clear from
            // either, so it is not worth keeping.
            Logger.w("UserDataStore: unreadable payload, discarding")
            UserDefaults.standard.removeObject(forKey: storageKey)
            return [:]
        }

        var out: [String: String] = [:]
        for key in DeeplinklyUserData.keys {
            if let value = object[key] as? String { out[key] = value }
        }
        return out
    }

    /// Merges `fields` over what is stored.
    ///
    /// Merge, not replace: an app learns an email at sign-up and an address at
    /// checkout, and the second call must not erase the first. Clearing one
    /// field is deliberately not expressible — that is what `clear()` is for.
    static func merge(_ fields: [String: String]) {
        guard !fields.isEmpty else { return }
        var merged = get()
        for (key, value) in fields where DeeplinklyUserData.keys.contains(key) {
            merged[key] = value
        }
        write(merged)
    }

    /// Replaces every set field with the empty string. See the type's note.
    static func clear() {
        let existing = get()
        guard !existing.isEmpty else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        write(existing.mapValues { _ in "" })
    }

    /// Whether anything has ever been set, tombstones included.
    static func isEmpty() -> Bool { get().isEmpty }

    private static func write(_ fields: [String: String]) {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: fields, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            Logger.w("UserDataStore: could not encode payload, leaving it unchanged")
            return
        }
        UserDefaults.standard.set(text, forKey: storageKey)
    }
}
