# iOS SDK integration guide

This guide covers native UIKit and SwiftUI integration with Deeplinkly. The SDK
supports iOS 12 and later through Swift Package Manager and CocoaPods.

## Install

### Swift Package Manager

Add `https://github.com/Deeplinkly/ios_deeplinkly` in Xcode's package
dependency editor and link the `Deeplinkly` library product to the app target.

For a package manifest:

```swift
dependencies: [
    .package(
        url: "https://github.com/Deeplinkly/ios_deeplinkly.git",
        from: "1.0.1"
    )
]
```

Add the product to the consuming target:

```swift
.product(name: "Deeplinkly", package: "ios_deeplinkly")
```

### CocoaPods

```ruby
pod 'Deeplinkly', '~> 1.0'
```

Then run `pod install` and use the generated `.xcworkspace`.

## Configure Info.plist

The API key is required. Link domains are strongly recommended and required
for deferred links on custom domains:

```xml
<key>DeeplinklyApiKey</key>
<string>your_api_key_here</string>

<key>DeeplinklyLinkDomains</key>
<array>
  <string>yourbrand.deeplinkly.com</string>
  <string>links.yourbrand.com</string>
</array>
```

Subdomains of a configured domain also match. When no domains are configured,
the automatic pasteboard path accepts only `deeplinkly.com` and its subdomains.

Optional configuration:

| Key | Type | Default | Purpose |
| --- | --- | --- | --- |
| `DeeplinklyAttributionLevel` | String | `full` | Initial `full`, `reduced`, `minimal`, or `none` enrichment level |
| `DeeplinklyCheckPasteboardOnInstall` | Boolean | `true` | Enables the once-per-install automatic deferred-link read |
| `DeeplinklyEnableIDFA` | Boolean | `false` | Allows IDFA collection after the app's own ATT prompt is authorized |

Use the Info.plist attribution key when the app must start with a restricted
level before its own code runs. A level saved later with
`setAttributionLevel(_:)` takes precedence and persists across launches.

### Register a custom scheme

If the project uses a custom-scheme fallback, add the scheme configured in the
dashboard:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.example.myapp</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>yourapp</string>
    </array>
  </dict>
</array>
```

## Configure Universal Links

In the app target's **Signing & Capabilities** tab, add **Associated Domains**
and one entry for each Deeplinkly link domain:

```text
applinks:yourbrand.deeplinkly.com
applinks:links.yourbrand.com
```

In the Deeplinkly dashboard, configure the exact bundle ID and Apple team ID
used to sign the app. Deeplinkly then serves the matching association file at:

```text
https://<your-link-domain>/.well-known/apple-app-site-association
```

Universal Links should be tested from Notes, Messages, Mail, or another app.
Pasting a URL into Safari's address bar is navigation and does not exercise
Universal Link handoff.

## Initialize and receive links

The SDK has one public delivery protocol:

```swift
import Deeplinkly

final class DeepLinkRouter: DeeplinklyDeepLinkListener {
    func onDeepLink(_ payload: [String: Any]) {
        let clickId = payload["click_id"] as? String
        let params = payload["params"] as? [String: Any] ?? [:]

        // Read your own routing values from params.
        if params["screen"] as? String == "product",
           let productId = params["product_id"] as? String {
            openProduct(productId)
        }
    }

    private func openProduct(_ id: String) {
        // Integrate with the app's router or navigation coordinator.
    }
}
```

The delivery envelope has these fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `click_id` | `String` or `NSNull` | Resolved click identifier, when one exists |
| `params` | `[String: Any]` | Link metadata and query parameters used for in-app routing |

`onDeepLink(_:)` always runs on the main thread. The SDK buffers a resolved
link until a listener is attached. Calling `handleLink(_:)` twice with the same
arrival is safe; in-flight and delivered links are deduplicated.

### AppDelegate integration

Attach the listener before initialization, then forward custom-scheme and
Universal Link callbacks:

```swift
import Deeplinkly
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private let router = DeepLinkRouter()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Deeplinkly.setDeepLinkListener(router)
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

If the app uses scenes, iOS delivers link callbacks to the scene delegate
instead. Keep initialization in the application delegate and add the methods
below.

### Forward links from a SceneDelegate

The cold-start URL is present in `connectionOptions`; warm links arrive through
the other two methods:

```swift
import Deeplinkly
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        for context in connectionOptions.urlContexts {
            Deeplinkly.handleLink(context.url)
        }
        for activity in connectionOptions.userActivities {
            if let url = activity.webpageURL {
                Deeplinkly.handleLink(url)
            }
        }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            Deeplinkly.handleLink(context.url)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let url = userActivity.webpageURL else { return }
        Deeplinkly.handleLink(url)
    }
}
```

### SwiftUI integration

Use `@UIApplicationDelegateAdaptor` for initialization and SwiftUI's
`onOpenURL` modifier for URL delivery:

```swift
import Deeplinkly
import SwiftUI
import UIKit

final class DeeplinklyAppDelegate: NSObject, UIApplicationDelegate {
    let router = DeepLinkRouter()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Deeplinkly.setDeepLinkListener(router)
        Deeplinkly.initialize()
        return true
    }
}

@main
struct ExampleApp: App {
    @UIApplicationDelegateAdaptor(DeeplinklyAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { Deeplinkly.handleLink($0) }
        }
    }
}
```

If the SwiftUI app installs a custom UIKit scene delegate instead of using
`onOpenURL`, forward the same scene callbacks shown above.

## Which URLs the SDK claims

A redirect-based Deeplinkly URL contains a `click_id`. The SDK resolves that
identifier regardless of whether the final URL uses `http`, `https`, or a
custom scheme.

When Universal Links bypass the redirect, the SDK resolves the first path
segment as a short code. That only happens for `http` and `https` URLs whose
host matches `DeeplinklyLinkDomains`. If the domain list is absent, all HTTP(S)
URLs handed to the SDK are eligible for short-code resolution.

Custom-scheme URLs without `click_id` are ignored. This prevents an app-owned
route such as `yourapp://settings/notifications` from being mistaken for a
Deeplinkly link.

Set `DeeplinklyLinkDomains` whenever the app has Universal Link entitlements
for non-Deeplinkly hosts. Otherwise, handing a marketing-site URL to the SDK
could make its first path segment look like a Deeplinkly short code.

## Deferred deep linking

iOS has no install-referrer API. Deeplinkly carries a pre-install link through
the App Store with the pasteboard: the interstitial copies the link after a
user gesture, and the SDK restores it on first launch.

There are two integration choices.

### Automatic read

The automatic read is enabled by default and runs once per install. Before
reading content, the SDK checks whether the pasteboard contains a URL without
showing a banner. If it finds one, reading that URL can show iOS's system
**“Pasted from…”** banner.

The SDK accepts the pasted URL only when its host matches
`DeeplinklyLinkDomains`. Without that key, only `deeplinkly.com` and its
subdomains are accepted. A matching link is queued before the automatic path
clears it, so an offline first launch can retry on a later launch.

Disable the automatic read before SDK initialization:

```xml
<key>DeeplinklyCheckPasteboardOnInstall</key>
<false/>
```

The same setting can be changed at runtime:

```swift
Deeplinkly.setCheckPasteboardOnInstall(false)
```

Enabling it at runtime checks immediately by default. Pass `checkNow: false`
when the UI needs to explain the read first:

```swift
Deeplinkly.setCheckPasteboardOnInstall(true, checkNow: false)

Deeplinkly.willShowPasteboardBanner { willShow in
    guard willShow else {
        Deeplinkly.checkPasteboardNow()
        return
    }

    presentPasteboardExplanation {
        Deeplinkly.checkPasteboardNow()
    }
}
```

For this priming flow, set `DeeplinklyCheckPasteboardOnInstall` to `false` in
Info.plist so the initialization-time read cannot race the UI. Enable it with
`checkNow: false` only when the priming screen is ready.

`willShowPasteboardBanner` reads no pasteboard content and shows no banner.
It returns `false` if the check is disabled, already completed, tracking is
disabled, or there is no URL-like content.

### Banner-free UIPasteControl

On iOS 16 and later, `UIPasteControl` gives the app the item only after the
user taps a system paste button. That user action avoids the paste banner.

```swift
import Deeplinkly
import UIKit

@available(iOS 16.0, *)
final class DeeplinklyPasteControlView: UIView {
    var onResult: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel

        let control = UIPasteControl(configuration: configuration)
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)

        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: centerXAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains {
            $0.hasItemConformingToTypeIdentifier("public.url") ||
            $0.hasItemConformingToTypeIdentifier("public.plain-text")
        }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        Deeplinkly.handlePaste(itemProviders: itemProviders) { [weak self] handled in
            self?.onResult?(handled)
        }
    }
}
```

The resolved link still arrives through `onDeepLink(_:)`. The completion only
reports whether the pasted content was a valid URL for one of the configured
domains. Unlike the automatic path, the SDK does not clear a deliberately
pasted item.

The automatic read is skipped while tracking is disabled. A user-initiated
paste remains available because it is an explicit deep-link action; device
enrichment is still suppressed.

## Attribution and identity

### First-touch attribution

```swift
let attribution = Deeplinkly.getInstallAttribution()
```

The map is empty until a link resolves. Once stored, later links do not replace
it. Depending on the link, it can contain:

- `click_id`
- `source`
- `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`
- `gclid`, `fbclid`, `ttclid`, `gbraid`, `wbraid`

### Deeplinkly install ID

```swift
let id = Deeplinkly.getDeeplinklyId()
```

This stable identifier is generated locally and works even when the SDK is
disabled because its API key is absent.

### Custom user ID

Associate the install with an authenticated account:

```swift
Deeplinkly.setUserId("user_123")
```

Clear the association on logout:

```swift
Deeplinkly.setUserId(nil)
```

## Attribution levels and tracking consent

Attribution levels filter the device block attached to enrichment and events:

| Level | Device information sent |
| --- | --- |
| `full` | All catalogued signals. This is the default. IDFA still requires explicit opt-in and authorized ATT status. |
| `reduced` | Coarse app, OS, locale, timezone, environment, and campaign context; high-entropy hardware and advertising identifiers are removed. |
| `minimal` | Install and app identity plus the link identity; no descriptive device profile. |
| `none` | No enrichment and no device block on events. Deep links and the event itself still work. |

Each level is a strict subset of the level above it. An unrecognized signal is
dropped even at `full`. See [the signal catalogue](SIGNALS.md) for every field.

Set and read the current level:

```swift
Deeplinkly.setAttributionLevel(.reduced)
let level = Deeplinkly.getAttributionLevel()
```

The selected level persists. To begin restricted before initialization, use
the `DeeplinklyAttributionLevel` Info.plist key.

For a complete reporting opt-out:

```swift
Deeplinkly.setTrackingEnabled(false)
let enabled = Deeplinkly.isTrackingEnabled()
```

This setting persists and takes precedence over the selected level. While it
is off:

- enrichment, events, and SDK error reports are not sent;
- the automatic pasteboard read is skipped;
- deep link resolution and delivery still work;
- generated-link requests still work; and
- `getAttributionLevel()` returns `.none` without overwriting the previously
  selected level.

Call the tracking setter before `initialize()` when consent must govern the
first launch work.

## Custom events

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
    // Main thread. False means validation or delivery failed.
}
```

Validation rules:

- The trimmed event name must be non-empty and at most 64 UTF-16 code units.
- At most 25 caller parameters are accepted.
- Parameter keys must be non-empty and at most 64 UTF-16 code units.
- Keys starting with `_dl_` are reserved for SDK metadata.
- Values may be strings, numbers, booleans, JSON-compatible arrays, or
  string-keyed JSON-compatible dictionaries.
- String values are limited to 256 UTF-16 code units.
- Arrays and dictionaries must encode to compact JSON no longer than 256 UTF-16
  code units.
- `NSNull` and other unsupported values are rejected.

Validation failures do not make a network request. Transient request failures
are queued for retry; the immediate completion still receives `false`.

At attribution level `.none`, the event is sent without a device block. With
tracking disabled, it is not sent.

## Generate a link

`generateLink` accepts the API's JSON-shaped payload directly:

```swift
let payload: [String: Any] = [
    "content": [
        "canonical_identifier": "product/sku_42",
        "title": "Pro Plan",
        "description": "Upgrade to Pro",
        "image_url": "https://example.com/images/pro.png",
        "metadata": [
            "screen": "product",
            "product_id": "sku_42",
        ],
    ],
    "options": [
        "channel": "email",
        "feature": "upgrade_campaign",
        "tags": ["spring", "sale"],
    ],
]

Deeplinkly.generateLink(payload: payload) { result in
    if result["success"] as? Bool == true {
        let url = result["url"] as? String
    } else {
        let code = result["error_code"] as? String
        let message = result["error_message"] as? String
    }
}
```

`canonical_identifier`, `channel`, and `feature` are required by the link
model. `tags` is an array of strings. Completions always run on the main thread
and always receive a result map.

## Public API reference

| API | Purpose |
| --- | --- |
| `Deeplinkly.initialize()` | Initialize from `DeeplinklyApiKey` in Info.plist |
| `Deeplinkly.initialize(apiKey:)` | Initialize with a key supplied by the app |
| `Deeplinkly.isEnabled` | Whether initialization received a non-empty key |
| `Deeplinkly.version` | Native SDK version |
| `Deeplinkly.setDeepLinkListener(_:)` | Attach or detach the resolved-link listener |
| `Deeplinkly.handleLink(_:)` | Forward an incoming Universal Link or custom-scheme URL |
| `Deeplinkly.takePendingLink()` | Remove and return a pre-initialization URL, primarily for adapter layers |
| `Deeplinkly.onForeground()` | Manually request the rate-limited app-open reporting path |
| `Deeplinkly.shutdown()` | Detach the listener |
| `Deeplinkly.getInstallAttribution()` | Read the persisted first-touch attribution map |
| `Deeplinkly.getDeeplinklyId()` | Read or create the local install identifier |
| `Deeplinkly.setUserId(_:)` | Set or clear the app's custom user identifier |
| `Deeplinkly.logEvent(_:parameters:completion:)` | Validate and report a custom event |
| `Deeplinkly.generateLink(payload:completion:)` | Create a Deeplinkly URL |
| `Deeplinkly.setTrackingEnabled(_:)` | Enable or disable all reporting |
| `Deeplinkly.isTrackingEnabled()` | Read the persistent reporting switch |
| `Deeplinkly.setAttributionLevel(_:)` | Set the persistent device-signal tier |
| `Deeplinkly.getAttributionLevel()` | Read the effective device-signal tier |
| `Deeplinkly.setDebugMode(_:)` | Enable or disable verbose SDK logs |
| `Deeplinkly.setCheckPasteboardOnInstall(_:checkNow:)` | Configure automatic deferred-link reading |
| `Deeplinkly.willShowPasteboardBanner(completion:)` | Probe whether an automatic read would show the system banner |
| `Deeplinkly.checkPasteboardNow()` | Run the enabled automatic pasteboard check |
| `Deeplinkly.handlePaste(itemProviders:completion:)` | Handle an explicit system paste-control action |

`initialize(apiKey:)` is useful when the key comes from build configuration or
another app-owned source. Initialization is idempotent, so the first call wins.
Native apps normally do not need `takePendingLink()`: `initialize` automatically
flushes the same buffered URL through the listener.

## Debugging and lifecycle

Enable verbose logs while developing:

```swift
Deeplinkly.setDebugMode(true)
```

Useful state:

```swift
print(Deeplinkly.version)
print(Deeplinkly.isEnabled)
```

`isEnabled` is `false` when initialization did not receive a usable API key.
Initialization is idempotent; later calls do not change the key.

`Deeplinkly.onForeground()` is normally unnecessary because the SDK observes
`UIApplication.didBecomeActiveNotification`. It is available for hosts with a
separate lifecycle bridge and is rate-limited with the automatic observer.

Call `Deeplinkly.shutdown()` to detach the listener. Reattach it with
`setDeepLinkListener(_:)` when the receiving layer becomes ready again.

## Privacy manifest and IDFA

The SDK bundles `PrivacyInfo.xcprivacy` with both SwiftPM and CocoaPods. It
declares the required-reason APIs and collected-data categories used by the
default, non-IDFA configuration.

The SDK does not request App Tracking Transparency permission. IDFA collection
is off by default. To opt in:

1. Add `DeeplinklyEnableIDFA` with a Boolean value of `true` to Info.plist.
2. Add `NSUserTrackingUsageDescription` to Info.plist.
3. Request authorization with `ATTrackingManager` in the app's own consent
   flow.
4. Merge the declarations from
   [`../Sources/Deeplinkly/Resources/IDFA/PrivacyInfo.xcprivacy`](../Sources/Deeplinkly/Resources/IDFA/PrivacyInfo.xcprivacy)
   into the app's privacy manifest.

The SDK collects IDFA only when all of the following are true: the build-time
flag is enabled, the current attribution level permits the field, and ATT
status is `authorized`.

## Troubleshooting

### `onDeepLink` never runs

- Confirm `Deeplinkly.isEnabled` is `true`.
- Attach the listener before or immediately after `initialize()`.
- Forward both custom-scheme and Universal Link delegate callbacks.
- In scene-based apps, handle `connectionOptions` for cold starts.
- Confirm the link contains a `click_id` or is an HTTP(S) short-code URL on a
  configured link domain.
- Enable debug mode and inspect logs tagged `Deeplinkly`.

### Universal Links open Safari

- Confirm the Associated Domains entitlement is present in the signed app.
- Confirm the domain, bundle ID, and team ID match the dashboard.
- Fetch the domain's `apple-app-site-association` endpoint and verify it is
  reachable without a redirect.
- Delete and reinstall the app after changing association data; iOS caches it.
- Test by tapping a link from another app, not by typing it into Safari.

### A deferred link is not restored

- Add the exact link host to `DeeplinklyLinkDomains`.
- Confirm the user tapped the App Store action on the Deeplinkly interstitial;
  a clipboard write requires a user gesture.
- Check whether automatic reading was disabled or already completed for this
  install.
- If tracking is disabled, use an explicit `UIPasteControl` action.
- For a custom domain, verify the pasted URL's host matches the configured
  domain or one of its subdomains.

### The paste banner appears

The banner is controlled by iOS when an app reads pasteboard content. Disable
`DeeplinklyCheckPasteboardOnInstall` and offer the iOS 16+
`UIPasteControl` flow for a fully user-initiated, banner-free restore action.
