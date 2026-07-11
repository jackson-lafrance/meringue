#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require_relative "../lib/meringue"

prompt = ARGV.join(" ").strip
prompt = "create one issue and spawn one worker for a harmless docs cleanup" if prompt.empty?

temp_root = Dir.mktmpdir("meringue-head-loop-smoke-")
project_path = File.join(temp_root, "demo-project")
state_path = File.join(temp_root, "state.json")
workspace_root = File.join(temp_root, "workspaces")
FileUtils.mkdir_p(project_path)
FileUtils.mkdir_p(workspace_root)
File.write(File.join(project_path, "README.md"), "# Head loop smoke demo\n")

store = Meringue::State::Store.new(path: state_path)
input = StringIO.new("#{prompt}\n/quit\n")

begin
  Meringue::Heads::SimpleLoop.new(
    input: input,
    out: $stdout,
    err: $stderr,
    initial_state: Meringue::State::Models.empty_state,
    cwd: project_path,
    store: store,
    runner: Meringue::Heads::FakeRunner.new,
    runner_name: "fake",
    harness_client: Meringue::Harness::FakeClient.new,
    workspace_manager: Meringue::Workspace::Manager.new(root_path: workspace_root)
  ).run

  puts "\nFinal persisted state:"
  puts JSON.pretty_generate(store.load)
ensure
  unless ENV["MERINGUE_KEEP_SMOKE"] == "1"
    FileUtils.remove_entry(temp_root) if Dir.exist?(temp_root)
  end
end
