# Builds only production UI/core sources in an isolated simulator app. No ML Kit or Rust engine.
require 'xcodeproj'
require 'fileutils'
root=File.expand_path('..',__dir__)
folder=File.join(root,'.build/photo-preview')
FileUtils.mkdir_p(folder)
project=Xcodeproj::Project.new(File.join(folder,'PhotoPreview.xcodeproj'))
target=project.new_target(:application,'PhotoPreview',:ios,'18.0')
files=Dir.glob(File.join(root,'Sources/ReadingCore/*.swift'))+Dir.glob(File.join(root,'App/*.swift')).reject { |file| %w[ReadingCompanionApp.swift RecognitionEngines.swift SudachiAnalyzer.swift BenchmarkModel.swift].include?(File.basename(file)) }+[File.join(root,'Tests/PhotoPreview/PreviewApp.swift')]
files.each { |file| target.source_build_phase.add_file_reference(project.main_group.new_file(file)) }
target.resources_build_phase.add_file_reference(project.main_group.new_file(File.join(root,'Resources/dictionary.sqlite')))
%w[fixture.json page.jpg].each { |name| target.resources_build_phase.add_file_reference(project.main_group.new_file(File.join(folder,name))) }
target.build_configurations.each do |config|
  config.build_settings.merge!({'PRODUCT_BUNDLE_IDENTIFIER'=>'com.joe.readingcompanion.uifixture','GENERATE_INFOPLIST_FILE'=>'YES','SWIFT_VERSION'=>'5.0','SWIFT_ACTIVE_COMPILATION_CONDITIONS'=>'UI_FIXTURE','CODE_SIGNING_ALLOWED'=>'NO','TARGETED_DEVICE_FAMILY'=>'1','INFOPLIST_KEY_UILaunchScreen_Generation'=>'YES','INFOPLIST_KEY_NSCameraUsageDescription'=>'Camera unavailable in fixture preview','OTHER_LDFLAGS'=>['$(inherited)','-lsqlite3']})
end
test=project.new_target(:ui_test_bundle,'PhotoPreviewUITests',:ios,'18.0')
test.source_build_phase.add_file_reference(project.main_group.new_file(File.join(root,'Tests/PhotoPreview/CorrectionGesturesUITests.swift')))
test.add_dependency(target)
test.build_configurations.each do |config|
  config.build_settings.merge!({'PRODUCT_BUNDLE_IDENTIFIER'=>'com.joe.readingcompanion.uifixture.tests','GENERATE_INFOPLIST_FILE'=>'YES','SWIFT_VERSION'=>'5.0','SWIFT_ACTIVE_COMPILATION_CONDITIONS'=>'UI_FIXTURE','CODE_SIGNING_ALLOWED'=>'NO','TEST_TARGET_NAME'=>'PhotoPreview','TARGETED_DEVICE_FAMILY'=>'1'})
end
scheme=Xcodeproj::XCScheme.new; scheme.add_test_target(test); scheme.add_build_target(target); scheme.set_launch_target(target); scheme.save_as(project.path,'PhotoPreview',true)
project.save
