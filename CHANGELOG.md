# Changelog

## 1.2.1 - 2026-08-30

- `SdkInfo.version` reported `1.0.1` while the package was 1.2.0, so 1.2.0
  misreports itself as 1.0.1 in `sdk_version` and in the static-profile stamp.
  The constant is hand-maintained -- `CFBundleShortVersionString` resolves to
  the host app in a static library -- and it was not bumped alongside the
  podspec. `tool/check_version.rb` exists to catch exactly this and does; 1.2.0
  was pushed without it.

  CocoaPods archives are immutable, so 1.2.0 cannot be corrected. This release
  supersedes it and there is no reason to use 1.2.0. No other change.

## 1.2.0 - 2026-08-27

- Signal catalogue version 13. `setPIIHashingEnabled(true)` hashes the
  identifying fields on the device with SHA-256 before they are sent, so
  plaintext never reaches Deeplinkly. Off by default, reported to the service
  as `pii_hashing_enabled` so it knows whether the columns hold digests.

  Only email, phone, first and last name are hashed. Gender, country and date
  of birth are not: their value ranges are small enough that a digest is
  reversed by enumerating them, so hashing them would be protection in
  appearance only while costing the storage width to hold it.

  It costs attribution quality and the trade is the customer's. A digest is
  computed once, under one normalisation, and advertising destinations disagree
  about phone formatting -- so a conversion forwarded to a destination whose
  rules differ will not match, and the service can no longer re-derive per
  destination because the value it would need is gone. Enable it when a
  compliance requirement says plaintext must not reach a processor.

  Hashing happens at send time, not in the store, so the switch is reversible.
  `user_phone` widened from 32 to 64 characters everywhere -- catalogue, both
  SDKs and the service column -- because that field now has to be able to hold
  a digest.

- Signal catalogue version 12. `setUserData` takes a `customData` map, carried
  as one JSON object under the new `user_custom_data` signal. It exists because
  a host app's binary is frozen for its whole release cycle while the list of
  identifiers a customer needs is not: attaching a Mixpanel distinct id, an
  Amplitude device id or a CleverTap id previously meant waiting for a new
  named field and a new app release. Now it is a service change.

  Bounded at 10 entries, 64-character keys and 256-character values, and
  encoded with sorted keys so the same map always produces the same string. One
  catalogue signal rather than open wire keys, so the published inventory and
  the `ErrorLog` redaction stay derived from a closed set. Treated exactly like
  the twelve named identifying fields: user scope, `minimal` tier, erased by
  `clearUserData()` and in scope for the erasure API.

- The failed-send retry queue moved from `UserDefaults` to the Keychain, under
  the same `ThisDeviceOnly` protection class `setUserData`'s own store uses. A
  queued enrichment is the whole assembled payload, so since catalogue 9 it can
  carry an email, phone, date of birth and postal address — and `UserDefaults`
  is a plist that rides into device backups and restores onto other hardware,
  which is precisely what moving the user data to the Keychain was meant to
  prevent. Queues written by an earlier build are carried over on first access
  and the plist copy is erased.
- Signal catalogue version 10. Adds the Google Ads auto-tagging markers
  `gad_source` and `gad_campaignid` (`reduced`/`identity`), which arrive on
  roughly half of Google Ads traffic with no `utm_source` at all — without them
  that traffic is indistinguishable from organic. No storage signals on iOS:
  every approved reason for `NSPrivacyAccessedAPICategoryDiskSpace` forbids
  sending the value off-device, so Meta's `extinfo` stays two elements short
  here permanently.
- Adds `Resources/ConversionForwarding/PrivacyInfo.xcprivacy`, a template to
  merge into your app's manifest if conversion forwarding is enabled for your
  Deeplinkly account. Forwarding joins your data with data Meta and Google hold
  from other apps, which is what ATT defines as tracking; the SDK's bundled
  manifest cannot declare that on every host app's behalf. Same pattern as the
  existing IDFA template.
- Registers the install with SKAdNetwork on `initialize()`
  (`updatePostbackConversionValue(0)` at iOS 16.1+, otherwise
  `registerAppForAdNetworkAttribution()`). Apple sends no postback unless the
  advertised app registers, so without this the endpoint below would never
  receive anything. Skipped while tracking is disabled; unaffected by the
  attribution level, since the postback is Apple's aggregate and carries no
  device data. Conversion values are not managed — do not call the StoreKit
  APIs yourself.
- Documents `NSAdvertisingAttributionReportEndpoint`. Declaring your Deeplinkly
  domain there makes Apple send the advertiser's copy of the winning
  SKAdNetwork postback to Deeplinkly. The key is compiled into your build and
  cannot be added remotely, and for ATT-denied users this is the only
  Apple-sanctioned install measurement path there is.

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
