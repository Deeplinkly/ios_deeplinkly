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
        from: "1.0.1"
    )
]
```

Then add `.product(name: "Deeplinkly", package: "ios_deeplinkly")` to the
target that imports the SDK.

### CocoaPods

```ruby
pod 'Deeplinkly', '~> 1.0'
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

## Privacy manifests and IDFA

SwiftPM and CocoaPods include the SDK's required-reason privacy manifest
automatically. The default SDK configuration does not collect IDFA and never
requests App Tracking Transparency permission.

IDFA collection is opt-in with `DeeplinklyEnableIDFA`. If enabled, the host app
must add `NSUserTrackingUsageDescription`, request ATT permission itself, and
merge [`Sources/Deeplinkly/Resources/IDFA/PrivacyInfo.xcprivacy`](Sources/Deeplinkly/Resources/IDFA/PrivacyInfo.xcprivacy)
into its own privacy manifest. The SDK reads IDFA only after the user has
authorized tracking.

## Documentation

- [Complete integration and API guide](docs/IOS_SDK.md)
- [Device signal catalogue](docs/SIGNALS.md)

## Development

Run the Swift package tests on a simulator:

```bash
xcodebuild test -scheme Deeplinkly \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Swift-package XCTest bundles do not receive an app Keychain access group, so
the package tests opt into a process-memory Keychain backend. Production always
uses Security.framework Keychain storage.

## Support

- Email: <support@deeplinkly.com>
- Issues: <https://github.com/Deeplinkly/ios_deeplinkly/issues>

## License

MIT License. See [`LICENSE`](LICENSE).
