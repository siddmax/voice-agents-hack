Pod::Spec.new do |s|
  s.name             = 'cactus'
  s.version          = '1.14.0'
  s.summary          = 'Cactus AI inference engine (vendored xcframework).'
  s.description      = 'Vendored libcactus xcframework from cactus-compute/cactus v1.14. Built via cactus/flutter/build.sh.'
  s.homepage         = 'https://github.com/cactus-compute/cactus'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Cactus Compute' => 'hello@cactuscompute.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '26.0'
  s.vendored_frameworks = 'Frameworks/cactus-ios.xcframework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => ''
  }
end
