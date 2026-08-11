# Deeplinkly iOS SDK

Deep linking, deferred deep linking, and attribution for iOS.

## Install

### Swift Package Manager

Add `https://github.com/Deeplinkly/ios_deeplinkly` and link the `Deeplinkly`
library product.

### CocoaPods

```ruby
pod 'Deeplinkly', '~> 1.9'
```

## Configure

Add the API key to the host app's `Info.plist`:

```xml
<key>DeeplinklyApiKey</key>
<string>your_api_key_here</string>
```

Initialize the SDK and attach a listener before forwarding links from the app
or scene delegate:

```swift
import Deeplinkly

Deeplinkly.initialize()
Deeplinkly.setDeepLinkListener(router)
```

The minimum deployment target is iOS 12.

## Privacy manifests

SwiftPM and CocoaPods include the required-reason API manifest automatically.
Apps that opt into IDFA collection should review and merge
`Sources/Deeplinkly/Resources/IDFA/PrivacyInfo.xcprivacy` into their own privacy
manifest; the template is intentionally not bundled by default.

## Tests

Run the 453-test SDK suite on a simulator:

```bash
xcodebuild test -scheme Deeplinkly \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Swift-package XCTest bundles do not receive an app Keychain access group, so
the package tests opt into a process-memory Keychain backend. The Flutter
example retains the same storage cases in an app-hosted target to exercise the
real Security.framework implementation. Production always uses Keychain.
