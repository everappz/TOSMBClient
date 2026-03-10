Pod::Spec.new do |s|
  s.name             = 'TOSMBClient'
  s.version          = '1.0.0'
  s.summary          = 'An Objective-C wrapper for libdsm providing SMB/CIFS client functionality.'
  s.description      = <<-DESC
    TOSMBClient is an Objective-C wrapper around libdsm, providing a
    high-level API for SMB/CIFS network file sharing. It supports NetBIOS
    discovery, browsing shares, downloading and uploading files.
  DESC

  s.homepage         = 'https://github.com/leshkoapps/TOSMBClient'
  s.license          = { :type => 'MIT and LGPL-2.1', :file => 'LICENSE.md' }
  s.author           = { 'leshkoapps' => 'https://github.com/leshkoapps' }
  s.source           = { :git => 'https://github.com/leshkoapps/TOSMBClient.git', :tag => s.version.to_s }

  s.ios.deployment_target     = '12.0'
  s.osx.deployment_target     = '10.15'
  s.tvos.deployment_target    = '9.0'
  s.watchos.deployment_target = '2.0'

  s.source_files = 'TOSMBClient/*.{h,m}'

  s.public_header_files = [
    'TOSMBClient/TOSMBClient.h',
    'TOSMBClient/TOHost.h',
    'TOSMBClient/TONetBIOSNameService.h',
    'TOSMBClient/TONetBIOSNameServiceEntry.h',
    'TOSMBClient/TOSMBConstants.h',
    'TOSMBClient/TOSMBSession.h',
    'TOSMBClient/TOSMBSessionFile.h',
    'TOSMBClient/TOSMBSessionTransferTask.h',
    'TOSMBClient/TOSMBSessionDownloadTask.h',
    'TOSMBClient/TOSMBSessionUploadTask.h'
  ]

  s.private_header_files = [
    'TOSMBClient/*+Private.h',
    'TOSMBClient/TOSMBCSessionWrapper.h',
    'TOSMBClient/NSString+TOSMB.h'
  ]

  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '"${PODS_ROOT}/Headers/Public/libdsm/src" "${PODS_ROOT}/Headers/Public/libdsm/include/bdsm"'
  }

  s.frameworks   = 'Foundation'
  s.requires_arc = true

  s.dependency 'libdsm', '~> 0.4'
end
