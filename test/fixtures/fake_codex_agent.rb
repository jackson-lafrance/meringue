#!/usr/bin/env ruby
# frozen_string_literal: true

# Stand-in Codex TUI for hermetic provider tests. It deliberately chooses its own session id only
# after the first prompt and writes Codex-shaped rollout JSONL under CODEX_HOME.

require "fileutils"
require "io/console"
require "json"
require "securerandom"
require "time"

codex_home = File.expand_path(ENV.fetch("CODEX_HOME"))
argv_log = ENV["FAKE_CODEX_ARGV_LOG"]
File.write(argv_log, JSON.generate(ARGV)) if argv_log

resume_index = ARGV.index("resume")
resume_id = resume_index && ARGV[resume_index + 1]
session_id = resume_id || SecureRandom.uuid
transcript = if resume_id
               Dir.glob(File.join(codex_home, "sessions", "**", "*#{resume_id}.jsonl")).first
             end
transcript ||= File.join(codex_home, "sessions", "2026", "08", "25", "rollout-2026-08-25T00-00-00-#{session_id}.jsonl")

$stdout.sync = true
$stdin.raw! rescue nil

if ENV["FAKE_CODEX_TRUST_PROMPT"] == "1"
  print "> You are in #{Dir.pwd}\r\n\r\n"
  print "  Do you trust the contents of this directory?\r\n\r\n"
  print "› 1. Yes, continue\r\n  2. No, quit\r\n\r\n  Press enter to continue\r\n"
  loop do
    character = $stdin.getc
    exit 1 if character.nil?
    break if character == "\r" || character == "\n"
  end
end

print "╭──────────────────────────────╮\r\n"
print "│ >_ OpenAI Codex (test)       │\r\n"
print "╰──────────────────────────────╯\r\n\r\n"
print "› Ask Codex to do anything\r\n\r\n  gpt-test medium · #{Dir.pwd}\r\n"

buffer = +""
paste = false
header_written = File.file?(transcript) && !File.zero?(transcript)

def append(path, record)
  FileUtils.mkdir_p(File.dirname(path))
  File.open(path, "a") { |file| file.puts(JSON.generate(record)) }
end

def now
  Time.now.utc.iso8601(3)
end

def clean_prompt(text)
  text.to_s.sub(/\n*<!-- meringue-delivery:.*?-->\s*\z/m, "").strip
end

loop do
  character = $stdin.getc
  break if character.nil?

  if character == "\e"
    sequence = +""
    while sequence.length < 5 && IO.select([$stdin], nil, nil, 0.05)
      following = $stdin.getc
      break if following.nil?

      sequence << following
      break if following == "~"
    end
    case sequence
    when "[200~" then paste = true
    when "[201~" then paste = false
    else
      buffer = +""
      append(transcript, {
        "timestamp" => now,
        "type" => "event_msg",
        "payload" => { "type" => "turn_aborted", "turn_id" => SecureRandom.uuid, "reason" => "interrupted" }
      }) if header_written
      print "\r\n■ interrupted\r\n› Ask Codex to do anything\r\n"
    end
    next
  end

  if character == "\r" || character == "\n" || character == "\t"
    if paste
      buffer << "\n"
      next
    end

    prompt = buffer.strip
    buffer = +""
    next if prompt.empty?

    unless header_written
      append(transcript, {
        "timestamp" => now,
        "type" => "session_meta",
        "payload" => {
          "id" => session_id,
          "session_id" => session_id,
          "timestamp" => now,
          "cwd" => Dir.pwd,
          "originator" => "codex-tui",
          "cli_version" => "test",
          "source" => "cli",
          "model_provider" => "openai"
        }
      })
      header_written = true
    end

    turn_id = SecureRandom.uuid
    append(transcript, {
      "timestamp" => now,
      "type" => "event_msg",
      "payload" => { "type" => "task_started", "turn_id" => turn_id, "model_context_window" => 100_000 }
    })
    append(transcript, {
      "timestamp" => now,
      "type" => "turn_context",
      "payload" => { "turn_id" => turn_id, "model" => "gpt-test", "effort" => "medium", "cwd" => Dir.pwd }
    })
    append(transcript, {
      "timestamp" => now,
      "type" => "event_msg",
      "payload" => { "type" => "user_message", "message" => prompt, "images" => [] }
    })
    print "\r\nworking\r\n"
    sleep 0.15

    if clean_prompt(prompt).include?("fail")
      append(transcript, {
        "timestamp" => now,
        "type" => "event_msg",
        "payload" => {
          "type" => "task_complete",
          "turn_id" => turn_id,
          "last_agent_message" => nil,
          "error" => { "message" => "connection reset by peer" }
        }
      })
      print "failed\r\n› Ask Codex to do anything\r\n"
      next
    end

    answer = "codex answered: #{clean_prompt(prompt)}"
    append(transcript, {
      "timestamp" => now,
      "type" => "event_msg",
      "payload" => { "type" => "agent_message", "message" => "Inspecting the workspace", "phase" => "commentary" }
    })
    append(transcript, {
      "timestamp" => now,
      "type" => "response_item",
      "payload" => {
        "type" => "message",
        "role" => "assistant",
        "phase" => "final_answer",
        "content" => [{ "type" => "output_text", "text" => answer }]
      }
    })
    append(transcript, {
      "timestamp" => now,
      "type" => "event_msg",
      "payload" => { "type" => "agent_message", "message" => answer, "phase" => "final_answer" }
    })
    append(transcript, {
      "timestamp" => now,
      "type" => "event_msg",
      "payload" => {
        "type" => "task_complete",
        "turn_id" => turn_id,
        "last_agent_message" => answer,
        "error" => nil,
        "completed_at" => now
      }
    })
    print "done\r\n› Ask Codex to do anything\r\n"
    next
  end

  buffer << character
  print character
end
