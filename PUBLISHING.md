# Publishing Deeplinkly for iOS

Swift Package Manager releases are the repository's full semantic-version Git
tags. The same tag is used by `Deeplinkly.podspec`, and the tag-triggered
release workflow publishes that specification to CocoaPods Trunk.

## One-time setup

1. Create a protected GitHub environment named `release`.
2. Register an organization-controlled CocoaPods Trunk account:
   `pod trunk register hello@deeplinkly.com 'Deeplinkly release'`.
3. Add its session token as the `COCOAPODS_TRUNK_TOKEN` secret in the `release`
   environment. Never commit the token or the local `.netrc` file.
4. Add at least one second Trunk owner after the first release.

## Release

1. Update `Deeplinkly.podspec` and `Sources/Deeplinkly/SdkInfo.swift` to the
   same full semantic version.
2. Add the release notes to `CHANGELOG.md`.
3. Run `ruby tool/check_version.rb`, the simulator test suite, and
   `pod lib lint Deeplinkly.podspec --skip-tests`.
4. Merge the release preparation pull request and wait for CI on `main`.
5. Create and push an annotated tag without a `v` prefix:

   ```bash
   git tag -a 1.0.0 -m "Deeplinkly iOS SDK 1.0.0"
   git push origin 1.0.0
   ```

The tag immediately makes the version available to Swift Package Manager. The
release workflow verifies the tag, publishes the immutable CocoaPods version,
and creates the GitHub release. Do not move or reuse a published version tag.
