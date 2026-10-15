# The iOS half of overblast_feedback for CocoaPods. The Swift package in overblast_feedback/ builds
# the same sources for apps on Swift Package Manager.
Pod::Spec.new do |s|
  s.name             = 'overblast_feedback'
  s.version          = '0.2.0'
  s.summary          = 'Device registration and report signing for overblast_feedback.'
  s.description      = <<-DESC
App Attest and a Secure Enclave P-256 key, behind the overblast_feedback/device method channel.
                       DESC
  s.homepage         = 'https://overblast.app'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Yumankind' => 'hello@yumankind.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'overblast_feedback/Sources/overblast_feedback/**/*.swift'
  s.dependency 'Flutter'
  # Xcode 27 builds nothing below iOS 15.0, so that is the floor. App Attest (iOS 14) and MetricKit's
  # crash diagnostics (iOS 14) are always there from it; the code still checks at run time.
  s.platform = :ios, '15.0'
  s.frameworks = 'DeviceCheck', 'Security'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
