Pod::Spec.new do |s|
  s.name             = 'Deeplinkly'
  s.module_name      = 'Deeplinkly'
  s.version          = '1.2.0'
  s.summary          = 'Deep linking, deferred deep linking, and attribution for iOS.'
  s.description      = <<-DESC
Deeplinkly resolves deep links, restores deferred destinations, records
first-touch attribution, and reports privacy-tiered device context on iOS.
                       DESC
  s.homepage         = 'https://deeplinkly.com'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Deeplinkly' => 'hello@deeplinkly.com' }
  s.source           = {
    :git => 'https://github.com/Deeplinkly/ios_deeplinkly.git',
    :tag => s.version.to_s
  }

  s.ios.deployment_target = '12.0'
  s.swift_version = '5.0'
  s.source_files = 'Sources/Deeplinkly/**/*.swift'

  # IDFA collection is opt-in and runtime-guarded on iOS 14+.
  s.weak_frameworks = 'AdSupport', 'AppTrackingTransparency'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }

  # Required-reason API declarations for UserDefaults, system uptime, file
  # timestamps, and disk space. The IDFA and ConversionForwarding variants are
  # opt-in templates for host apps to merge into their own manifests, and are
  # deliberately excluded from the shipped resource bundle: Xcode aggregates
  # every bundled manifest into the containing app's privacy report, so a
  # tracking declaration here would be made on behalf of every host app.
  s.resource_bundles = {
    'DeeplinklyPrivacy' => ['Sources/Deeplinkly/Resources/PrivacyInfo.xcprivacy']
  }
end
