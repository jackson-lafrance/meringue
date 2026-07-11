#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/meringue/harness/client"
require_relative "../lib/meringue/harness/pi_client"
require_relative "../lib/meringue/heads/runner"
require_relative "../lib/meringue/heads/pi_runner"

user_message = ARGV.join(" ").strip
if user_message.empty?
  user_message = "create one issue and one worker for a harmless documentation cleanup request"
end

temp_root = Dir.mktmpdir("meringue-pi-head-")
cwd = File.join(temp_root, "workspace")
session_dir = File.join(temp_root, "pi-sessions")
FileUtils.mkdir_p(cwd)
FileUtils.mkdir_p(session_dir)

snapshot = {
  "schema_version" => 1,
  "projects" => [
    {
      "id" => "P1",
      "name" => "SmokeProject",
      "root_path" => cwd,
      "status" => "working"
    }
  ],
  "issues" => [],
  "agents" => [],
  "questions" => [],
  "logs" => []
}

client = Meringue::Harness::PiClient.new(
  session_dir: session_dir,
  extra_args: [
    "--thinking", "minimal",
    "--tools", "read,bash,grep,find,ls",
    "--no-extensions",
    "--no-skills",
    "--no-prompt-templates",
    "--no-context-files"
  ],
  event_timeout: 90
)
runner = Meringue::Heads::PiRunner.new(harness_client: client, cwd: cwd, timeout: 90)

begin
  result = runner.run(user_message: user_message, snapshot: snapshot)
  puts "Pi HeadResult:"
  puts JSON.pretty_generate(result)
rescue Meringue::Heads::PiRunner::InvalidHeadResultError => e
  warn "Pi returned invalid HeadResult JSON:"
  warn e.validation_errors.join("\n")
  warn "\nRaw assistant output:"
  warn e.raw_output
  exit 1
ensure
  FileUtils.remove_entry(temp_root) if Dir.exist?(temp_root)
end
