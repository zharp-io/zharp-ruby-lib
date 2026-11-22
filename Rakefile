# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = false
end

# Rails in a process of its own: OpenTelemetry instruments what is loaded when Zharp starts.
Rake::TestTask.new(:test_rails) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/rails/*_test.rb"]
  t.warning = false
end

rails = begin
  Gem::Specification.find_by_name("railties")
rescue Gem::MissingSpecError
  nil
end

task default: rails ? %i[test test_rails] : :test
