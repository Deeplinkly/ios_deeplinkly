# Changelog

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
