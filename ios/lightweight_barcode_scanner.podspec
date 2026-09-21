#
# Lightweight barcode scanner: AVFoundation for capture, a vendored ZXing-C++
# reader core for decoding. No ML runtime, no network, no Apple Vision.
#
Pod::Spec.new do |s|
  s.name             = 'lightweight_barcode_scanner'
  s.version          = '0.1.0'
  s.summary          = 'Offline barcode & QR scanner powered by a shared ZXing-C++ core.'
  s.description      = <<-DESC
Lightweight, offline barcode and QR scanner. Camera frames are decoded inside
the native capture pipeline by a shared C++ core; Flutter only receives the
decoded results.
                       DESC
  s.homepage         = 'https://github.com/enver/lightweight_barcode_scanner'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Enver Erdem' => 'envererdem18@gmail.com' }
  s.source           = { :path => '.' }

  # CocoaPods drops source_files outside the podspec directory, so the shared
  # C++ core - which has to stay at the package root for the Android build and
  # the host tests - is pulled in through the one-line forwarders in
  # Classes/forwarders (see tool/generate_ios_sources.sh).
  s.source_files = 'Classes/**/*'
  s.preserve_paths = [
    '../src/**/*',
    '../third_party/zxing-cpp/**/*',
  ]
  # Only the Objective-C surface is public; the C++ headers stay internal.
  s.public_header_files = 'Classes/LBSDecoder.h'

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
  s.libraries = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # ZXing includes its headers unqualified, and Version.h is generated at
    # vendoring time into its own directory.
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/../src"',
      '"$(PODS_TARGET_SRCROOT)/../third_party/zxing-cpp/core/src"',
      '"$(PODS_TARGET_SRCROOT)/../third_party/zxing-cpp/core/generated"',
    ].join(' '),
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) ZXING_INTERNAL=1',
    # Reader-only core: keep the symbols we do not call out of the binary.
    'DEAD_CODE_STRIPPING' => 'YES',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'YES',
  }

  s.resource_bundles = {
    'lightweight_barcode_scanner_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }
end
