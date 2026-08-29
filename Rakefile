# frozen_string_literal: true

require "rake/testtask"

Dir[File.expand_path("tasks/**/*.rake", __dir__)].sort.each { |task_file| load task_file }

Rake::TestTask.new(:test) do |t|
  t.libs = ["lib", "test"]
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test
