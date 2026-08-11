import Foundation

enum UserIdManager {
    static func updateCustomUserId(newId: String?, apiKey: String) {
        // Get the currently stored ID
        let previousId = Prefs.customUserId()

        // If it's the same, no change
        if previousId == newId { return }

        // Persist the new ID
        Prefs.setCustomUserId(newId)

        // Optional: log it
        Logger.d("UserIdManager: updated custom user ID → \(newId ?? "nil")")

        // Link the id to the TenantUser now. force: linking a login has nothing
        // to do with attribution, so it must not be gated on a UTM being
        // present — a user who installed the app organically would otherwise
        // never be linked at all.
        // The new id is already stored, so the sender reads it back with the
        // rest of the payload. Nothing to pass but the source.
        EnrichmentSender.sendOnce(
            attributionData: [:],
            source: "custom_user_id",
            apiKey: apiKey,
            force: true
        )
    }
}
