require 'xcodeproj'
project = Xcodeproj::Project.new('ReadingCompanion.xcodeproj')
target = project.new_target(:application, 'ReadingCompanion', :ios, '18.0')
%w[App Sources/ReadingCore].each do |directory|
  group = project.main_group.new_group(directory)
  Dir.glob("#{directory}/**/*.swift").sort.each { |file| target.source_build_phase.add_file_reference(group.new_file(file)) }
end
resources = project.main_group.new_group('Resources')
%w[Resources/dictionary.sqlite Resources/tessdata Resources/sudachi Resources/Attribution.txt].each do |file|
  next unless File.exist?(file)
  ref = resources.new_file(file)
  ref.last_known_file_type = 'folder' if File.directory?(file)
  target.resources_build_phase.add_file_reference(ref)
end
if ENV['INCLUDE_BENCHMARK'] == '1'
  ref=resources.new_file('Benchmark/private/device-corpus')
  ref.last_known_file_type='folder'
  target.resources_build_phase.add_file_reference(ref)
end
package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
package.repositoryURL = 'https://github.com/SwiftyTesseract/SwiftyTesseract.git'
package.requirement = {'kind'=>'exactVersion','version'=>'4.0.1'}
project.root_object.package_references << package
dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dependency.package=package
dependency.product_name='SwiftyTesseract'
target.package_product_dependencies << dependency
build_file=project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref=dependency
target.frameworks_build_phase.files << build_file
# Link the archive by filename: -lsudachi_bridge prefers Rust's adjacent dylib,
# whose install name points at this Mac and causes dyld to abort on iPhone.
target.build_configurations.each do |c|
  c.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER'=>'com.joe.readingcompanion',
    'SWIFT_VERSION'=>'5.0', 'GENERATE_INFOPLIST_FILE'=>'YES',
    'INFOPLIST_KEY_NSCameraUsageDescription'=>'Capture Japanese pages for offline reading assistance.',
    'INFOPLIST_KEY_NSMotionUsageDescription'=>'Detect a steady phone before capturing a reading page.',
    'INFOPLIST_KEY_UIFileSharingEnabled'=>'YES',
    'INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace'=>'YES',
    'INFOPLIST_KEY_UILaunchScreen_Generation'=>'YES',
    'INFOPLIST_KEY_UISupportedInterfaceOrientations'=>'UIInterfaceOrientationPortrait',
    'TARGETED_DEVICE_FAMILY'=>'1',
    'SWIFT_OBJC_BRIDGING_HEADER'=>'App/Native.h',
    'SUDACHI_STATIC_LIBRARY[sdk=iphoneos*]'=>'$(SRCROOT)/Native/target/aarch64-apple-ios/release/libsudachi_bridge.a',
    'SUDACHI_STATIC_LIBRARY[sdk=iphonesimulator*]'=>'$(SRCROOT)/Native/target/x86_64-apple-ios/release/libsudachi_bridge.a',
    'OTHER_LDFLAGS'=>['$(inherited)','"$(SUDACHI_STATIC_LIBRARY)"','-lsqlite3','-lc++','-lz','-liconv'],
    'CODE_SIGN_STYLE'=>'Automatic', 'ENABLE_USER_SCRIPT_SANDBOXING'=>'NO',
    'SWIFT_STRICT_CONCURRENCY'=>'minimal'
  })
end
scheme=Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project.path,'ReadingCompanion',true)
project.save
