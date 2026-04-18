Pod::Spec.new do |s|
  s.name             = 'cactus'
  s.version          = '1.14.0'
  s.summary          = 'Cactus AI inference engine (vendored framework, simulator).'
  s.description      = <<-DESC
    Vendored libcactus.framework from cactus-compute/cactus v1.14, simulator
    arm64 slice extracted from the upstream xcframework via build.sh. Hackathon
    scope is iOS simulator first; device builds need the device slice copied
    into Frameworks/ as a separate step (see DEMO.md).
  DESC
  s.homepage         = 'https://github.com/cactus-compute/cactus'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Cactus Compute' => 'hello@cactuscompute.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '26.0'
  s.vendored_frameworks = 'Frameworks/cactus.framework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => ''
  }
end
