#!/usr/bin/env ruby

podspec = File.read("Deeplinkly.podspec")
sdk_info = File.read("Sources/Deeplinkly/SdkInfo.swift")

podspec_version = podspec[/s\.version\s*=\s*['\"]([^'\"]+)['\"]/, 1]
sdk_version = sdk_info[/static let version\s*=\s*"([^"]+)"/, 1]

abort "Could not read the podspec version" unless podspec_version
abort "Could not read SdkInfo.version" unless sdk_version
unless podspec_version.match?(/\A\d+\.\d+\.\d+\z/)
  abort "Package version is not a stable semantic-version triple: #{podspec_version}"
end
unless podspec_version == sdk_version
  abort "Version mismatch: podspec=#{podspec_version}, SDK=#{sdk_version}"
end

expected = ARGV.first
if expected && expected != podspec_version
  abort "Release tag #{expected} does not match package version #{podspec_version}"
end

puts "Deeplinkly version is consistent: #{podspec_version}"
