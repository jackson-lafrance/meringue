#!/usr/bin/env ruby
# frozen_string_literal: true

# A stand-in agent CLI that behaves like the interactive coding agents Meringue drives.
#
# It exists so the interactive transport can be tested for real — a PTY, a rendered prompt box,
# bracketed-paste input, an interrupt key, and a JSONL transcript written as work happens — without
# a network call or a vendor install. What it deliberately does *not* do is make the transport's job
# easy: it renders a banner before it is ready, echoes pasted text, takes visible time to "think",
# and writes its transcript incrementally, because those are the behaviours the transport has to
# cope with against a real agent.
#
#   fake_interactive_agent.rb --session-id ID --transcript-dir DIR [--boot-delay S] [--turn-delay S]
#
# Test-only switches:
#   --fail-turn      answer with an API-error record instead of a normal reply
#   --tool-turn      emit a tool call and its result before the final answer
#   --no-transcript  never write a transcript, to exercise the unreadable-session path
#   --exit-before-answer  exit after recording the prompt, before writing an assistant response

require "fileutils"
require "io/console"
require "json"
require "securerandom"

options = {
  "session_id" => SecureRandom.uuid,
  "transcript_dir" => Dir.pwd,
  "boot_delay" => 0.2,
  "turn_delay" => 0.2,
  "fail_turn" => false,
  "tool_turn" => false,
  "exit_before_answer" => false,
  "styled_turn" => false,
  "transcript" => true
}

argv = ARGV.dup
until argv.empty?
  flag = argv.shift
  case flag
  when "--session-id" then options["session_id"] = argv.shift
  when "--resume" then options["session_id"] = argv.shift
  when "--transcript-dir" then options["transcript_dir"] = argv.shift
  when "--boot-delay" then options["boot_delay"] = argv.shift.to_f
  when "--turn-delay" then options["turn_delay"] = argv.shift.to_f
  when "--fail-turn" then options["fail_turn"] = true
  when "--tool-turn" then options["tool_turn"] = true
  when "--exit-before-answer" then options["exit_before_answer"] = true
  when "--styled-turn" then options["styled_turn"] = true
  when "--no-transcript" then options["transcript"] = false
  when "--system-prompt", "--name", "--model", "--effort" then argv.shift
  end
end

transcript = File.join(options.fetch("transcript_dir"), "#{options.fetch("session_id")}.jsonl")
FileUtils.mkdir_p(File.dirname(transcript)) if options.fetch("transcript")

def append(path, record)
  File.open(path, "a") { |file| file.puts(JSON.generate(record)) }
end

def now
  Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
end

$stdout.sync = true
# Real agent CLIs take the terminal out of canonical mode so they can react to single keystrokes.
# Without it the PTY line-buffers and echoes input, and a lone escape key would not arrive until the
# user pressed Enter, so the interrupt path could never be exercised.
begin
  $stdin.raw!
rescue StandardError
  nil
end

# Boot output before the prompt box exists, so a transport that types too early types into nothing.
print "fake-agent starting\r\n"
sleep options.fetch("boot_delay")
print "ready\r\n"
print "❯ \r\n"

interrupted = false
buffer = +""
paste = false
pending = nil

loop do
  character = $stdin.getc
  break if character.nil?

  if character == "\e"
    # An escape is either the interrupt key or the start of a bracketed-paste marker. Only bytes
    # arriving immediately after it can tell the two apart.
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
      interrupted = true
      pending = nil
      buffer = +""
      print "\r\ninterrupted\r\n\u276f \r\n"
    end
    next
  end

  if character == "\r" || character == "\n"
    if paste
      buffer << "\n"
      next
    end
    pending = buffer.strip
    buffer = +""
    next if pending.empty?

    working_label = options.fetch("styled_turn") ? "\e[1;33mworking on\e[0m" : "working on"
    print "\r\n#{working_label}: #{pending[0, 40]}\r\n"
    prompt_uuid = SecureRandom.uuid
    if options.fetch("transcript")
      append(transcript, {
        "type" => "user",
        "uuid" => prompt_uuid,
        "parentUuid" => nil,
        "isSidechain" => false,
        "timestamp" => now,
        "sessionId" => options.fetch("session_id"),
        "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => pending }] }
      })
    end

    sleep options.fetch("turn_delay")
    exit 42 if options.fetch("exit_before_answer")

    if options.fetch("tool_turn") && options.fetch("transcript")
      tool_uuid = SecureRandom.uuid
      append(transcript, {
        "type" => "assistant", "uuid" => tool_uuid, "parentUuid" => prompt_uuid, "isSidechain" => false,
        "timestamp" => now, "sessionId" => options.fetch("session_id"),
        "message" => {
          "role" => "assistant", "stop_reason" => "tool_use",
          "content" => [{ "type" => "tool_use", "id" => "call_1", "name" => "read", "input" => { "path" => "README.md" } }]
        }
      })
      print "running tool\r\n"
      sleep options.fetch("turn_delay")
      append(transcript, {
        "type" => "user", "uuid" => SecureRandom.uuid, "parentUuid" => tool_uuid, "isSidechain" => false,
        "timestamp" => now, "sessionId" => options.fetch("session_id"),
        "message" => {
          "role" => "user",
          "content" => [{ "type" => "tool_result", "tool_use_id" => "call_1", "content" => "file contents" }]
        }
      })
      sleep options.fetch("turn_delay")
    end

    if options.fetch("transcript")
      record = if options.fetch("fail_turn")
                 {
                   "type" => "assistant", "uuid" => SecureRandom.uuid, "parentUuid" => prompt_uuid,
                   "isSidechain" => false, "isApiErrorMessage" => true, "timestamp" => now,
                   "sessionId" => options.fetch("session_id"),
                   "message" => {
                     "role" => "assistant", "stop_reason" => "end_turn",
                     "content" => [{ "type" => "text", "text" => "API Error: connection reset by peer" }]
                   }
                 }
               else
                 {
                   "type" => "assistant", "uuid" => SecureRandom.uuid, "parentUuid" => prompt_uuid,
                   "isSidechain" => false, "timestamp" => now, "sessionId" => options.fetch("session_id"),
                   "message" => {
                     "role" => "assistant", "stop_reason" => "end_turn",
                     "content" => [{ "type" => "text", "text" => "answered: #{pending}" }]
                   }
                 }
               end
      append(transcript, record)
    end

    if options.fetch("styled_turn")
      print "\e[1;32mdone\e[0m\r\n\e[1;36m❯\e[0m \r\n"
    else
      print "done\r\n❯ \r\n"
    end
    next
  end


  buffer << character
  # A real prompt box echoes what is typed, which is what a viewer's screen shows.
  print character
end

exit(interrupted ? 130 : 0)
