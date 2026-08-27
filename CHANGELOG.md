# Changelog

## 1.2.0 - 2026-08-27

- Adds `setUserData()`, for the email, phone, name and address a conversion is
  matched on at Meta's Conversions API and Google's enhanced conversions. This
  is the platform where it matters most: with App Tracking Transparency denied
  there is no IDFA, so a hashed email is the only match key that still exists.
- Values are stored and sent as supplied, and hashed only when a conversion is
  forwarded. On-device hashing would look safer and buy nothing — the digest of
  a normalised email is exactly the value Meta matches on.
- Adds `clearUserData()`, which erases those fields here *and* on the server:
  each previously-set field is reported empty until the erasure is delivered,
  so a clear on an offline device still takes effect. `PrivacyData.reset()`
  removes the local store too.
- Adds `logPurchase(value:currency:...)`, a typed wrapper over `logEvent` that
  sends the `purchase` event with the one spelling of `value`/`currency` both
  destinations can be built from. `logEvent` now validates those two keys
  wherever they appear, so a hand-rolled purchase gets the same answer.
- Every event now carries a client-generated `_dl_event_id`. It is Meta CAPI's
  `event_id`, and it makes a replay off the retry queue idempotent.
- Signal catalogue version 9, with a new `user` scope. `custom_user_id` moves
  into it from `identity`. User data is classified `minimal`, so it survives a
  `.reduced` downgrade — the levels gate what we *observe* about a device, and
  an email the person typed into your app is not an observation.

## 1.1.0 - 2026-08-27

- Collects the Google Ads `gbraid` and `wbraid` click identifiers. Signal
  catalogue version 8; both are classified `reduced`/`identity`, so they ship
  at every level except `none`.
- Carries both on the resolve query, the attribution snapshot, and the
  enrichment payload. iOS Google App campaigns deliver `gbraid` precisely
  because there is no IDFA to match on, and the SDK was discarding it.

## 1.0.1 - 2026-08-16

- Makes tracking opt-out strict for reporting: pending retries are purged,
  disabled requests cannot be requeued, and retry drains re-check consent.
- Omits stable Deeplinkly and custom-user identity headers from functional
  resolve/generate requests while tracking is disabled.
- Adds `resetPrivacyData()` to delete local identifiers, attribution, device,
  session, pasteboard, and queue state while leaving tracking disabled.

## 1.0.0 - 2026-08-12

- Initial standalone Deeplinkly SDK release for iOS.
- Supports Swift Package Manager and CocoaPods at the iOS 12 deployment floor.
- Includes deep-link resolution, deferred deep linking, attribution, event
  reporting, privacy-tiered device context, retry persistence, and privacy
  manifests.
