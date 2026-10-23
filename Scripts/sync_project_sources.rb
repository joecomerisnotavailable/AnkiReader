# Add new source files without regenerating the project or changing signing/Pods.
require 'xcodeproj'
project = Xcodeproj::Project.open('ReadingCompanion.xcodeproj')
target = project.targets.find { |item| item.name == 'ReadingCompanion' }
%w[App Sources/ReadingCore].each do |directory|
  group = project.main_group.groups.find { |item| item.name == directory }
  Dir.glob("#{directory}/**/*.swift").sort.each do |path|
    ref = project.files.find { |item| item.path == path } || group.new_file(path)
    target.source_build_phase.add_file_reference(ref) unless target.source_build_phase.files_references.include?(ref)
  end
end
project.save
