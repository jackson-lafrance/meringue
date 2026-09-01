# frozen_string_literal: true

require "rake/testtask"

Dir[File.expand_path("tasks/**/*.rake", __dir__)].sort.each { |task_file| load task_file }

ALL_TEST_FILES = FileList["test/**/*_test.rb"].to_a.sort
SMOKE_TEST_FILES = %w[
  test/integration/foundation/command_blacklist_test.rb
  test/integration/foundation/delivery_artifact_policy_test.rb
  test/integration/harness/commit_identity_test.rb
  test/integration/harness/process_identity_test.rb
  test/integration/input/input_kernel_convergence_test.rb
  test/integration/kernel_maintenance/clear_state_test.rb
  test/integration/workspace/manager_git_isolation_test.rb
].freeze

def selected_test_files(files = ALL_TEST_FILES)
  selected = files
  if ENV["TEST_SHARD"]
    shard = Integer(ENV.fetch("TEST_SHARD"))
    shards = Integer(ENV.fetch("TEST_SHARDS", "1"))
    abort "TEST_SHARD must be between 1 and TEST_SHARDS" unless shard.between?(1, shards)
    selected = files.each_with_index.select { |_, index| index % shards == shard - 1 }.map(&:first)
  end
  abort "No test files selected" if selected.empty?
  selected
end

def test_task(name, files = ALL_TEST_FILES)
  Rake::TestTask.new(name) do |t|
    t.libs = ["lib", "test"]
    t.test_files = selected_test_files(files)
    t.warning = false
  end
end

test_task(:test)
test_task("test:smoke", SMOKE_TEST_FILES)

task default: :test
