// UserDataStore.swift
import Foundation

/// The person's own details, as the host app reported them.
///
/// ## Where this lives
///
/// The Keychain, under ``Keychain/thisDeviceOnly``, not `UserDefaults`.
///
/// `UserDefaults` is a plist in the app container. It is readable on a
/// jailbroken or unlocked-and-trusted device, and it is copied into device
/// backups — including unencrypted local ones — from which it restores onto
/// whatever hardware the backup is opened on. That is an acceptable home for a
/// session id or a dedupe latch. It is not one for an email address, a phone
/// number, a date of birth and a postal address, which is what this holds once
/// `setUserData` has been called.
///
/// The `ThisDeviceOnly` protection class is the half that matters: a plain
/// Keychain item is still backed up and still restores elsewhere. What the
/// suffix buys is that these values cannot outlive this install on other
/// hardware.
///
/// One key holding one JSON object, rather than a key per field.
/// That is not only tidiness: `PrivacyData.persistedKeys` is a hand-maintained
/// inventory of everything the SDK writes, and eleven separately-named fields
/// would be eleven chances for whoever adds a twelfth to miss one — in the one
/// list where missing an entry means personal data survives a deletion.
///
/// ## Clearing
///
/// `clear()` does not simply delete the blob. A key that stops being sent is
/// indistinguishable, at the service, from a key that was never sent — the
/// enrichment path skips absent values so a phone that failed to read its
/// carrier cannot blank the carrier we already know. So clearing writes a
/// tombstone instead: every key that currently holds a value is rewritten to
/// the empty string, which the service reads as "erase this column".
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
        guard let raw = readRaw(), let data = raw.data(using: .utf8)
        else { return [:] }

        guard let decoded = try? JSONSerialization.jsonObject(with: data),
            let object = decoded as? [String: Any]
        else {
            // A blob we cannot parse is a blob we cannot honour a clear from
            // either, so it is not worth keeping.
            Logger.w("UserDataStore: unreadable payload, discarding")
            purge()
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
            purge()
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
        if !Keychain.set(text, for: storageKey, accessibility: Keychain.thisDeviceOnly) {
            // Losing the write silently would mean a `clear()` tombstone that
            // never reaches the service, which is the one failure this type
            // exists to prevent. There is nowhere safer to fall back to, so say
            // so rather than degrade to UserDefaults.
            Logger.w("UserDataStore: keychain write failed; details not persisted")
        }
    }

    /// Deletes the record outright, tombstones and all.
    ///
    /// Distinct from ``clear()``, which keeps a tombstone precisely so the
    /// erasure survives to be delivered. This is for `resetPrivacyData()` and
    /// for a payload too corrupt to honour — cases where nothing is owed to the
    /// service and the right answer is that the value stops existing.
    static func purge() {
        Keychain.delete(storageKey)
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// The stored blob, migrating one written before this moved to the Keychain.
    ///
    /// No released iOS version ever wrote the `UserDefaults` copy — `setUserData`
    /// arrived with catalogue 9 and has not shipped — so in production this
    /// fallback is dead on arrival. It exists for devices carrying a pre-release
    /// build, where the alternative is worse than dead: a stale blob of personal
    /// data left in the store this type just moved off, holding a `clear()`
    /// tombstone that would never be delivered. Migrating is what empties it.
    private static func readRaw() -> String? {
        if let value = Keychain.get(storageKey) { return value }
        guard let legacy = UserDefaults.standard.string(forKey: storageKey)
        else { return nil }
        Logger.d("UserDataStore: migrating pre-release payload into the keychain")
        Keychain.set(legacy, for: storageKey, accessibility: Keychain.thisDeviceOnly)
        UserDefaults.standard.removeObject(forKey: storageKey)
        return legacy
    }
}
