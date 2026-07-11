#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "tmpdir"

require_relative "../lib/meringue/harness/client"
require_relative "../lib/meringue/harness/pi_client"

options = {
  cwd: nil,
  prompt: nil,
  keep_alive: false,
  keep_temp: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby -Ilib scripts/pi_headless_smoke.rb [options]"

  parser.on("--cwd PATH", "Working directory for the Pi RPC session. Defaults to a temp dir.") do |path|
    options[:cwd] = path
  end

  parser.on("--prompt PROMPT", "Optionally send one prompt after get_state/session naming.") do |prompt|
    options[:prompt] = prompt
  end

  parser.on("--keep-alive", "Do not kill the Pi process before exiting.") do
    options[:keep_alive] = true
  end

  parser.on("--keep-temp", "Do not remove the temp cwd/session directory.") do
    options[:keep_temp] = true
  end
end.parse!

temp_root = Dir.mktmpdir("meringue-pi-headless-")
cwd = File.expand_path(options[:cwd] || File.join(temp_root, "workspace"))
session_dir = File.join(temp_root, "pi-sessions")
FileUtils.mkdir_p(cwd)
FileUtils.mkdir_p(session_dir)

client = Meringue::Harness::PiClient.new(
  session_dir: session_dir,
  extra_args: ["--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files"]
)
session_ref = nil

begin
  session_ref = client.spawn_session(
    kind: "smoke",
    cwd: cwd,
    prompt: nil,
    system_prompt: nil,
    session_name: "Meringue headless smoke"
  )

  puts "Spawned Pi RPC session:"
  puts JSON.pretty_generate(session_ref)

  if options[:prompt]
    session_ref = client.prompt_session(session_ref, options[:prompt], mode: "normal")
    events = client.wait_for_settled(session_ref)
    puts "\nPrompt settled after #{events.length} structured event(s)."
    puts "Last assistant text:"
    puts client.last_assistant_text(session_ref)
  end

  drained_events = client.read_events(session_ref)
  puts "\nDrained #{drained_events.length} queued structured event(s)." unless drained_events.empty?
ensure
  client.kill_session(session_ref) if session_ref && !options[:keep_alive]
  FileUtils.remove_entry(temp_root) if Dir.exist?(temp_root) && !options[:keep_temp]
end
