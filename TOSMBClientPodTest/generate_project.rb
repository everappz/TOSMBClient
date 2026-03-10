require 'xcodeproj'

project_path = File.join(__dir__, 'TOSMBClientPodTest.xcodeproj')
project = Xcodeproj::Project.new(project_path)

# Create main group
main_group = project.main_group
src_group = main_group.new_group('Sources')

# Add source files
main_ref = src_group.new_file('main.m')
plist_ref = src_group.new_file('Info.plist')

# Create iOS app target
target = project.new_target(:application, 'TOSMBClientPodTest', :ios, '12.0')
target.add_file_references([main_ref])

# Configure build settings
target.build_configurations.each do |config|
  config.build_settings['INFOPLIST_FILE'] = 'Info.plist'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.test.TOSMBClientPodTest'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['CODE_SIGN_IDENTITY'] = '-'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
end

project.save

puts "Project created at #{project_path}"
