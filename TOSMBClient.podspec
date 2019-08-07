Pod::Spec.new do |s|
  s.name     = 'TOSMBClient'
  s.version  = '1.0.1'
  s.license  =  { :type => 'MIT', :file => 'LICENSE.md' }
  s.summary  = 'An Objective-C framework that wraps libdsm, an SMB client library.'
  s.homepage = 'https://github.com/TimOliver/TOSMBClient'
  s.author   = 'Tim Oliver'
  s.source   = { :git => 'https://github.com/leshkoapps/TOSMBClient.git', :tag => '1.0.1', :submodules => true }
  s.platform = :ios, '7.0'
  s.source_files = 'TOSMBClient/*.{h,m}', 'TOSMBClient/libdsm/xcode/*.{h}', 'TOSMBClient/libdsm/xcode/extra/*.{h,c}', 'TOSMBClient/libdsm/src/*.{c}', 'TOSMBClient/libdsm/libtasn1/include/*.{h}', 'TOSMBClient/libdsm/include/*.{h}', 'TOSMBClient/libdsm/include/bdsm/*.{h}', 'TOSMBClient/libdsm/contrib/mdx/*.{h,c}', 'TOSMBClient/libdsm/contrib/rc4/*.{h,c}', 'TOSMBClient/libdsm/contrib/spnego/*.{h,c}', 'TOSMBClient/libdsm/compat/*.{h,c}',
  s.vendored_libraries = 'TOSMBClient/libdsm/libtasn1/libtasn1.a'
  s.library = 'iconv'
  s.requires_arc = true
end
