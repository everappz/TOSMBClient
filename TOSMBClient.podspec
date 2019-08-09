Pod::Spec.new do |s|
  s.name     = 'TOSMBClient'
  s.version  = '1.0.1'
  s.license  =  { :type => 'MIT', :file => 'LICENSE.md' }
  s.summary  = 'An Objective-C framework that wraps libdsm, an SMB client library.'
  s.homepage = 'https://github.com/TimOliver/TOSMBClient'
  s.author   = 'Tim Oliver'
  s.source   = { :git => 'https://github.com/leshkoapps/TOSMBClient.git', :tag => '1.0.1', :submodules => true }
  s.platform = :ios, '7.0'
  s.source_files = 'TOSMBClient/*.{h,m}',
  'TOSMBClient/libdsm/xcode/**/*.{h,c}',
  'TOSMBClient/libdsm/xcode/*.{h,c}',
  'TOSMBClient/libdsm/src/*.{h,c}',
  'TOSMBClient/libdsm/libtasn1/**/*.{h,c}',
  'TOSMBClient/libdsm/include/**/*.{h,c}', 
  'TOSMBClient/libdsm/contrib/**/*.{h,c}',
  'TOSMBClient/libdsm/compat/strndup.c',
  'TOSMBClient/libdsm/compat/queue.h',
  'TOSMBClient/libdsm/compat/compat.h',
  'TOSMBClient/libdsm/compat/compat.c',
  'TOSMBClient/libdsm/compat/clock_gettime.c'
  s.vendored_libraries = 'TOSMBClient/libdsm/libtasn1/libtasn1.a'
  s.public_header_files = 'TOSMBClient/TOSMBSessionUploadTask.h',
  'TOSMBClient/TOSMBSessionFile.h',
  'TOSMBClient/TOSMBSessionDownloadTask.h',
  'TOSMBClient/TOSMBSession.h',
  'TOSMBClient/TOSMBCSessionWrapper.h',
  'TOSMBClient/TOSMBConstants.h',
  'TOSMBClient/TONetBIOSNameServiceEntry.h',
  'TOSMBClient/TONetBIOSNameService.h',
  'TOSMBClient/TOHost.h',
  'TOSMBClient/NSString+TOSMB.h',
  'TOSMBClient/TOSMBClient.h'
  s.private_header_files = 'TOSMBClient/libdsm/xcode/config.h'
  s.library = 'iconv'
  s.requires_arc = true
  s.xcconfig = { 'HEADER_SEARCH_PATHS' => "${PODS_ROOT}/#{s.name}/**" }
end
