# Deeplinkly iOS SDK

Deeplinkly's native Swift SDK for deep linking, deferred deep linking,
first-touch attribution, privacy-tiered enrichment, event tracking, and link
generation on iOS.

## Features

- Universal Link and custom-scheme resolution
- Deferred deep linking across an App Store install
- Offline resolve queue with retry on a later launch
- Stable Deeplinkly install ID and optional custom user ID
- First-touch install attribution
- Validated custom events
- Runtime attribution and tracking controls
- Swift Package Manager and CocoaPods support
- Bundled Apple privacy manifest

The minimum deployment target is iOS 12.

## Installation

### Swift Package Manager

In Xcode, choose **File > Add Package Dependencies** and enter:

```text
https://github.com/Deeplinkly/ios_deeplinkly
```

Select the `Deeplinkly` product and add it to your app target. For a
`Package.swift` dependency:

```swift
dependencies: [
    .package(
        url: "https://github.com/Deeplinkly/ios_deeplinkly.git",
        from: "1.2.1"
    )
]
```

Then add `.product(name: "Deeplinkly", package: "ios_deeplinkly")` to the
target that imports the SDK.

### CocoaPods

```ruby
pod 'Deeplinkly', '~> 1.2'
```

Run `pod install`, open the generated workspace, and import `Deeplinkly` in
your Swift code.

## Configure the app

Add the API key and every domain that can host your Deeplinkly links to the
app's `Info.plist`:

```xml
<key>DeeplinklyApiKey</key>
<string>your_api_key_here</string>

<key>DeeplinklyLinkDomains</key>
<array>
  <string>yourbrand.deeplinkly.com</string>
  <string>links.yourbrand.com</string>
</array>
```

For custom-scheme fallback links, also register the scheme configured in the
Deeplinkly dashboard:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>yourapp</string>
    </array>
  </dict>
</array>
```

For Universal Links, add the **Associated Domains** capability and one entry
per link domain:

```text
applinks:yourbrand.deeplinkly.com
applinks:links.yourbrand.com
```

The Deeplinkly dashboard must contain the app's bundle ID and Apple team ID so
the domain can serve a matching `apple-app-site-association` file.

## Quick start

Implement `DeeplinklyDeepLinkListener`, attach it during launch, and forward
every URL entry point to the SDK:

```swift
import Deeplinkly
import UIKit

final class DeepLinkRouter: DeeplinklyDeepLinkListener {
    func onDeepLink(_ payload: [String: Any]) {
        let clickId = payload["click_id"] as? String
        let params = payload["params"] as? [String: Any] ?? [:]

        print("Deeplinkly click: \(clickId ?? "direct")")
        print("Parameters: \(params)")
        // Route to the relevant screen.
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private let deepLinkRouter = DeepLinkRouter()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Deeplinkly.setDeepLinkListener(deepLinkRouter)
        Deeplinkly.initialize()
        return true
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Deeplinkly.handleLink(url)
        return true
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard let url = userActivity.webpageURL else { return false }
        Deeplinkly.handleLink(url)
        return true
    }
}
```

Apps that use scenes must also forward the `UISceneDelegate` URL callbacks,
including the cold-start `connectionOptions`. See
[`docs/IOS_SDK.md`](docs/IOS_SDK.md#forward-links-from-a-scene-delegate) for a
complete example.

The listener always runs on the main thread. Links that resolve before a
listener is attached are buffered and delivered after attachment.

## Core API

### Attribution and identity

```swift
let attribution = Deeplinkly.getInstallAttribution()
let deeplinklyId = Deeplinkly.getDeeplinklyId()

Deeplinkly.setUserId("user_123")
Deeplinkly.setUserId(nil) // clear the custom user ID
```

`getInstallAttribution()` is first-touch data. It is empty until the first link
resolves and is not overwritten by later links.

### User data

The fields a conversion is matched on once it reaches Meta's Conversions API or
Google's enhanced conversions:

```swift
let stored = Deeplinkly.setUserData(
    userId: "user_123",
    email: "ada@example.com",
    phoneNumber: "+441234567890",
    firstName: "Ada",
    lastName: "Lovelace",
    city: "London",
    country: "GB"
)   // false if any field was malformed, in which case nothing was stored
```

Every field is optional and each call **merges**, so you can supply an email at
sign-up and an address at checkout. A malformed field rejects the whole call —
nothing is stored — so you never have to guess which of the values took.

Constraints, enforced before anything is stored: `dateOfBirth` is `YYYY-MM-DD`;
`gender` is `"m"` or `"f"`, the only two values Meta's `ge` accepts, and
anything else is refused rather than coerced; `country` is ISO-3166-1 alpha-2.
Per-field maximum lengths are listed in [SIGNALS.md](docs/SIGNALS.md).

Supply only what your own privacy policy and consent flow allow — the SDK
cannot know what you told your users. These fields survive a `reduced`
downgrade, because the attribution levels gate what the SDK *observes* about a
device and an email someone typed into your app is not an observation. At
`none` nothing is sent.

`customData` carries identifiers Deeplinkly does not name — typically your own
product-analytics ids:

```swift
Deeplinkly.setUserData(
    userId: "user_123",
    customData: [
        "mixpanel_distinct_id": "d-8837",
        "clevertap_id": "ct-4412",
    ]
)
```

It exists because your binary is frozen for its whole release cycle while the
list of identifiers you need is not. Bounded at 10 entries, 64-character keys
and 256-character values; anything larger rejects the whole call.

To erase everything recorded — on sign-out, or when someone withdraws consent:

```swift
Deeplinkly.clearUserData()
```

This is not merely "stop sending": the next enrichment reports each
previously-set field as empty, which the service reads as "null this column".
The erasure is re-sent until it is delivered, so calling it on a device that is
offline still takes effect once it is not. To clear only the id, call
`setUserId(nil)`.

### Purchases

```swift
Deeplinkly.logPurchase(
    value: 49.99,
    currency: "USD",
    orderId: "ord_42",
    quantity: 1,
    productId: "sku_9"
) { accepted in /* optional */ }
```

A typed wrapper over `logEvent` rather than a separate pipeline: it sends the
event named `purchase` with `value` and `currency` set, and everything true of
`logEvent` — the retry queue, the parameter limits, the device block — is true
of this too.

It exists because those two keys have to be spelled the same way by every
caller. Meta's Conversions API wants `custom_data.value` and `currency`; Google
wants a conversion value and currency. This is the one spelling both can be
built from.

Rejected, sending nothing, if the value is negative or not finite (a refund is a
different event, not a negative purchase), the currency is not three letters,
the quantity is negative, or `parameters` contains any of the keys this method
sets. `orderId` is worth passing: it is what Google deduplicates conversions on,
and how you reconcile a forwarded conversion against your own records.

### Event logging

```swift
Deeplinkly.logEvent(
    "purchase",
    parameters: [
        "order_id": "ord_42",
        "amount": 49.99,
        "currency": "USD",
        "is_first_purchase": true,
    ]
) { accepted in
    print("Event accepted: \(accepted)")
}
```

Event names and parameter values are validated before a request is sent. The
completion runs on the main thread.

### Link generation

```swift
let payload: [String: Any] = [
    "content": [
        "canonical_identifier": "product/sku_42",
        "title": "Pro Plan",
        "description": "Upgrade to Pro",
        "metadata": ["plan": "pro"],
    ],
    "options": [
        "channel": "email",
        "feature": "upgrade_campaign",
        "tags": ["spring", "sale"],
    ],
]

Deeplinkly.generateLink(payload: payload) { result in
    if result["success"] as? Bool == true,
       let url = result["url"] as? String {
        print("Generated link: \(url)")
    } else {
        print(result["error_message"] as? String ?? "Link generation failed")
    }
}
```

## Privacy controls

Restrict the device signals included with enrichment and events:

```swift
Deeplinkly.setAttributionLevel(.reduced)
```

The levels are `full` (default), `reduced`, `minimal`, and `none`. Deep link
resolution and delivery work at every level. At `.none`, events can still be
sent, but without a device block.

Use the tracking switch for a complete reporting opt-out:

```swift
Deeplinkly.setTrackingEnabled(false)
```

While disabled, the SDK sends no enrichment, events, or SDK error reports,
deletes pending reporting retries, and skips its automatic pasteboard read.
Deep links still resolve and deliver, but functional requests omit the stable
Deeplinkly ID and custom user ID. The setting persists across launches and
takes precedence over the selected attribution level.

To hash the identifying fields on the device before they are sent:

```swift
Deeplinkly.setPIIHashingEnabled(true)
Deeplinkly.isPIIHashingEnabled()   // off unless you turned it on
```

Off by default. With it on, email, phone, first and last name are SHA-256 hashed
on the device and plaintext never reaches Deeplinkly. The state is reported as
`pii_hashing_enabled` so the service knows whether the columns hold digests.

Only those four are hashed. Gender, country and date of birth are not: their
value ranges are small enough that a digest is reversed by enumerating them, so
hashing them would be protection in appearance only.

**It costs attribution quality, and the trade is yours.** A digest is computed
once, under one normalisation, and advertising destinations disagree about phone
formatting — so a conversion forwarded to a destination whose rules differ will
not match, and the service can no longer re-derive per destination because the
value it would need is gone. Enable it when a compliance requirement says
plaintext must not reach a processor, not by default. Hashing happens at send
time rather than in the store, so the switch is reversible.

For a deletion request:

```swift
Deeplinkly.resetPrivacyData()
```

This deletes the locally stored Deeplinkly ID, custom user ID, attribution,
cached device profile, session/event and pasteboard state, and pending queues.
It leaves tracking disabled so deletion cannot immediately create and report a
replacement identity.

## Deferred deep linking

The automatic deferred-link check is enabled by default. On the first launch,
the SDK performs a banner-free probe and reads the pasteboard only when it
contains a URL. Reading the URL can show iOS's **“Pasted from…”** banner.

Disable the automatic read in `Info.plist`:

```xml
<key>DeeplinklyCheckPasteboardOnInstall</key>
<false/>
```

On iOS 16 and later, a native `UIPasteControl` can give users a banner-free
“restore link” action. The user gesture is the paste permission; pass the
control's item providers to `Deeplinkly.handlePaste(itemProviders:completion:)`.
The detailed guide includes a ready-to-use UIKit implementation.

## Privacy manifests, IDFA, and conversion forwarding

SwiftPM and CocoaPods include the SDK's required-reason privacy manifest
automatically. It declares what the default configuration collects — including
the contact details `setUserData()` accepts, which are declared whether or not
your app ever calls it. The default configuration does not collect IDFA, never
requests App Tracking Transparency permission, and makes no tracking claim.

Two opt-ins change that, and each ships a template to merge into your own app's
`PrivacyInfo.xcprivacy`. They are independent: an app may need both, either, or
neither. Neither template is bundled, deliberately — Xcode aggregates every
bundled manifest into the containing app's privacy report, so a tracking
declaration inside the SDK would be made on behalf of every app that embeds it.

- **IDFA**, opt-in with `DeeplinklyEnableIDFA`. Add
  `NSUserTrackingUsageDescription`, request ATT permission yourself, and merge
  [`Sources/Deeplinkly/Resources/IDFA/PrivacyInfo.xcprivacy`](Sources/Deeplinkly/Resources/IDFA/PrivacyInfo.xcprivacy).
  The SDK reads IDFA only after the user has authorized tracking.
- **Conversion forwarding to Meta or Google**, enabled on your Deeplinkly
  account rather than in code. Forwarding joins your data with data those
  companies hold from other apps, which is ATT's definition of tracking — for
  hashed values as much as raw ones, and regardless of the forwarding happening
  on our servers rather than in your app. Merge
  [`Sources/Deeplinkly/Resources/ConversionForwarding/PrivacyInfo.xcprivacy`](Sources/Deeplinkly/Resources/ConversionForwarding/PrivacyInfo.xcprivacy),
  add the ATT prompt, and move those types to **Data Used to Track You** in your
  App Store privacy labels.

## Documentation

- [Complete integration and API guide](docs/IOS_SDK.md)
- [Device signal catalogue](docs/SIGNALS.md) — every field the SDK may send and
  the lowest attribution level at which each still ships. This is the reference
  to use when filling in your App Store **privacy label** or your own privacy
  notice; those declarations must cover what your app configures the SDK to
  send, not only the defaults.
- [Data & Privacy](https://www.deeplinkly.com/docs/privacy) — what the service
  stores, what `setUserData()` makes you the controller of, and how retention
  and deletion work today.
- [Deeplinkly Privacy Policy](https://www.deeplinkly.com/privacy-policy) — the
  binding document: recipients, legal bases, and transfers.

## Development

Run the Swift package tests on a simulator:

```bash
xcodebuild test -scheme Deeplinkly \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Swift-package XCTest bundles do not receive an app Keychain access group, so
the package tests opt into a process-memory Keychain service. Production always
uses Security.framework Keychain storage.

## Support

- Email: <support@deeplinkly.com>
- Issues: <https://github.com/Deeplinkly/ios_deeplinkly/issues>

## License

MIT License. See [`LICENSE`](LICENSE).
